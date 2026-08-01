#!/usr/bin/env python3
"""
Telegram VS Code Mini App Bot
Allows users to open VS Code from Telegram via Web App
"""

import os
import json
import logging
import shutil
import subprocess
import tempfile
import yaml
from datetime import datetime
from pathlib import Path
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, MenuButtonCommands, MenuButtonWebApp, WebAppInfo
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = Path(__file__).parent / "config.yaml"
ENV_FILE = Path(__file__).parent / ".env"
# state.json: chỉ bot.py đọc/ghi, KHÔNG đụng tới config.yaml — setup.sh ghi đè
# config.yaml toàn bộ mỗi lần chạy lại, sẽ xoá mất owner_chat_id nếu để chung.
STATE_FILE = Path(__file__).parent / "state.json"
BACKUP_SCRIPT = Path(__file__).parent / "scripts" / "backup-ai-configs.sh"

def load_config():
    """Load configuration from config.yaml"""
    if not CONFIG_FILE.exists():
        logger.error(f"❌ config.yaml not found. Copy from config.example.yaml")
        raise FileNotFoundError("config.yaml is required")
    
    with open(CONFIG_FILE, 'r') as f:
        config = yaml.safe_load(f)
    
    return config

def load_env_fallback():
    """Load from .env file as fallback"""
    if ENV_FILE.exists():
        import dotenv
        dotenv.load_dotenv(ENV_FILE)

# Load configuration
try:
    CONFIG = load_config()
except FileNotFoundError:
    load_env_fallback()
    CONFIG = {
        'TELEGRAM_BOT_TOKEN': os.getenv('TELEGRAM_BOT_TOKEN'),
        'VSCODE_PUBLIC_URL': os.getenv('VSCODE_PUBLIC_URL'),
        'VSCODE_PORT': int(os.getenv('VSCODE_PORT', 8443)),
    }

TELEGRAM_BOT_TOKEN = CONFIG.get('TELEGRAM_BOT_TOKEN')
VSCODE_PUBLIC_URL = CONFIG.get('VSCODE_PUBLIC_URL', 'http://localhost:8443')
# Mã claim quyền owner 1 lần, sinh bởi setup.sh — bắt buộc để chống race condition
# "ai /start trước làm chủ" (bug thật: bot token/username lộ ra trước khi chủ thật
# bấm /start lần đầu thì kẻ tấn công tự nhận owner, dùng được /backup_configs).
OWNER_CLAIM_CODE = CONFIG.get('OWNER_CLAIM_CODE')
# Thư mục nhận file gửi qua Telegram — mặc định là thư mục con "files" trong thư
# mục cài telecode (không phải chính $DIR — tránh trộn lẫn với source code thực
# thi), đổi được ở bước 6d của setup.sh / field tương ứng trong wizard.
FILE_INBOX_DIR = CONFIG.get('FILE_INBOX_DIR') or str(Path(__file__).parent / "files")

if not TELEGRAM_BOT_TOKEN:
    logger.error("❌ TELEGRAM_BOT_TOKEN not found in config or environment")
    raise ValueError("TELEGRAM_BOT_TOKEN is required")

# Validate URLs
if not VSCODE_PUBLIC_URL:
    logger.warning("⚠️  VSCODE_PUBLIC_URL not configured. Using default.")
    VSCODE_PUBLIC_URL = "http://localhost:8443"

logger.info(f"✅ Bot configured:")
logger.info(f"   Bot Token: {TELEGRAM_BOT_TOKEN[:10]}...")
logger.info(f"   VS Code URL: {VSCODE_PUBLIC_URL}")


def load_state() -> dict:
    if not STATE_FILE.exists():
        return {"owner_chat_id": None}
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {"owner_chat_id": None}


def save_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, indent=2))


def is_owner(update: Update) -> bool:
    owner_chat_id = load_state().get("owner_chat_id")
    return owner_chat_id is not None and update.effective_chat.id == owner_chat_id


def discover_tailnet_peers() -> list[tuple[str, str]]:
    """Liệt kê máy đang online trong tailnet (chỉ gọi lệnh cục bộ `tailscale status`,
    không cần token/API riêng). Trả về [] nếu Tailscale chưa cài/chưa cấu hình trên
    máy đang chạy bot.py — start() fallback về VSCODE_PUBLIC_URL của chính instance
    này khi rỗng, giữ tương thích ngược cho máy chưa cài Tailscale."""
    try:
        out = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
        data = json.loads(out)
    except Exception:
        return []

    peers = []
    self_info = data.get("Self") or {}
    if self_info.get("DNSName"):
        peers.append((self_info.get("HostName", "self"), self_info["DNSName"].rstrip(".")))
    for peer in (data.get("Peer") or {}).values():
        if peer.get("Online") and peer.get("DNSName"):
            peers.append((peer.get("HostName", "peer"), peer["DNSName"].rstrip(".")))
    return peers


async def discover_alive_servers() -> list[tuple[str, str]]:
    """Health-check các máy trong tailnet (hoặc VSCODE_PUBLIC_URL nếu không có
    Tailscale), trả về [] nếu không máy nào online. Dùng chung cho start() và
    post_init() (đặt menu button)."""
    peers = discover_tailnet_peers()
    candidates = peers if peers else [("VS Code", VSCODE_PUBLIC_URL.replace("https://", "").replace("http://", ""))]

    import aiohttp
    alive = []
    async with aiohttp.ClientSession() as session:
        for name, dns in candidates:
            url = f"https://{dns}" if not dns.startswith("http") else dns
            try:
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=3)) as resp:
                    alive.append((name, url))
            except Exception:
                continue
    return alive


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Start command handler — bot cá nhân 1 chủ sở hữu duy nhất:
    - Chưa ai claim owner: bắt buộc /start <mã-claim> (in ra lúc chạy setup.sh) mới
      được ghi nhận owner_chat_id. Không còn kiểu "ai /start trước làm chủ" (race
      condition thật: bot token/username lộ ra trước khi chủ thật bấm /start lần
      đầu thì kẻ tấn công tự nhận owner, dùng được /backup_configs).
    - Đã có owner: chỉ đúng owner mới nhận được URL/danh sách máy online — người
      khác nhắn bot nhận từ chối chung chung (không lộ VSCODE_PUBLIC_URL)."""
    user = update.message.from_user
    logger.info(f"👤 User started bot: {user.first_name} (@{user.username})")

    state = load_state()
    if state.get("owner_chat_id") is None:
        if not OWNER_CLAIM_CODE or not context.args or context.args[0] != OWNER_CLAIM_CODE:
            await update.message.reply_text(
                "🔒 Bot chưa được xác nhận chủ sở hữu.\n"
                "Dùng: /start <mã-claim> (mã in ra lúc chạy setup.sh trên máy cài telecode)."
            )
            return
        state["owner_chat_id"] = update.effective_chat.id
        save_state(state)
        logger.info(f"✅ Đã xác nhận chủ sở hữu: chat_id={update.effective_chat.id}")
    elif not is_owner(update):
        await update.message.reply_text("⛔ Bot này chỉ phục vụ chủ sở hữu.")
        return

    alive = await discover_alive_servers()

    if not alive:
        await update.message.reply_text("⚠️ Hiện chưa có server telecode nào online. Kiểm tra lại code-server/tailscale trên máy chạy telecode.")
        return

    # web_app=WebAppInfo(...) thay vì url=... — bug thật đã gặp: nút kiểu url=
    # (Telegram tự mở bằng trình duyệt trong-app riêng của nó) báo "Không thể
    # truy cập trang web này" trên 1 máy thật dù server hoàn toàn bình thường
    # (xác nhận qua curl trực tiếp IP relay Funnel công khai, bypass hẳn máy chạy
    # server), trong khi icon Menu Button (đã dùng WebAppInfo từ trước, xem
    # post_init() bên dưới) mở CÙNG URL đó vẫn vào bình thường — khác biệt duy
    # nhất là cơ chế mở, không phải server/DNS/Tailscale. Dùng WebAppInfo cho cả
    # /start lẫn Menu Button để nhất quán, tránh phụ thuộc trình duyệt trong-app
    # (vốn không phải WebView tiêu chuẩn của Telegram, hành vi tuỳ phiên
    # bản/nền tảng, không đáng tin cậy bằng Mini App WebView chính thức).
    if len(alive) == 1:
        name, url = alive[0]
        keyboard = InlineKeyboardMarkup([[InlineKeyboardButton(f"🔧 Mở VS Code ({name})", web_app=WebAppInfo(url=url))]])
        text = "🚀 *VS Code Remote Control*\n\nBấm nút bên dưới để mở VS Code từ điện thoại!"
    else:
        keyboard = InlineKeyboardMarkup([[InlineKeyboardButton(f"🖥️ {name}", web_app=WebAppInfo(url=url))] for name, url in alive])
        text = "🚀 *VS Code Remote Control*\n\nCó nhiều máy đang online — chọn máy muốn mở:"

    await update.message.reply_text(text, parse_mode='Markdown', reply_markup=keyboard)


async def backup_configs_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """/backup_configs <passphrase> — chỉ chủ sở hữu gọi được. Đóng gói + mã hoá
    cấu hình AI CLI tool (claude/copilot/gemini/deepseek) trên máy đang chạy bot.py
    này, gửi lại vào chính chat dưới dạng file .gpg."""
    if not is_owner(update):
        await update.message.reply_text("⛔ Lệnh này chỉ dành cho chủ sở hữu bot.")
        return
    if not context.args:
        await update.message.reply_text("Dùng: /backup_configs <passphrase>\n(Passphrase dùng để mã hoá — cần nhớ để giải mã lại ở máy đích.)")
        return
    passphrase = " ".join(context.args)

    # Xoá ngay tin nhắn chứa passphrase (best-effort, private chat cho phép bot
    # xoá message trong vòng 48h) để không lưu passphrase dạng plaintext lâu trong lịch sử chat.
    try:
        await update.message.delete()
    except Exception:
        pass

    if not BACKUP_SCRIPT.exists():
        await context.bot.send_message(update.effective_chat.id, "❌ Thiếu scripts/backup-ai-configs.sh")
        return

    status_msg = await context.bot.send_message(update.effective_chat.id, "⏳ Đang đóng gói cấu hình AI tool...")
    tmp_out = Path(tempfile.mkstemp(suffix=".tar.gz.gpg")[1])
    try:
        proc = subprocess.run(
            ["bash", str(BACKUP_SCRIPT), str(tmp_out)],
            input=passphrase, capture_output=True, text=True, timeout=60,
        )
        if proc.returncode != 0:
            await status_msg.edit_text(f"❌ Sao lưu thất bại:\n{proc.stderr[-500:]}")
            return
        await context.bot.send_document(
            update.effective_chat.id,
            document=tmp_out.open("rb"),
            filename="telecode-ai-configs.tar.gz.gpg",
            caption="🔐 Bundle cấu hình AI tool (mã hoá AES256). Dùng đúng passphrase vừa nhập để giải mã ở máy đích.",
        )
        await status_msg.delete()
    except Exception as e:
        await status_msg.edit_text(f"❌ Lỗi: {e}")
    finally:
        if tmp_out.exists():
            shutil.rmtree(tmp_out, ignore_errors=True) if tmp_out.is_dir() else tmp_out.unlink(missing_ok=True)

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Help command handler"""
    if not is_owner(update):
        await update.message.reply_text("⛔ Bot này chỉ phục vụ chủ sở hữu.")
        return
    help_text = (
        "🔧 *VS Code Mini App - Help*\n\n"
        "*Commands:*\n"
        "/start - Giới thiệu (nút mở VS Code nằm ở menu 🔧 cạnh khung nhập tin nhắn)\n"
        "/help - Show this help\n"
        "/status - Check connection status\n\n"
        "*Troubleshooting:*\n"
        "• Make sure code-server is running on your PC\n"
        "• Check that the tunnel is active\n"
        "• Verify internet connection\n"
        "• Try refreshing the page\n\n"
        "*Need help?*\n"
        "Check README.md in the project folder."
    )
    
    await update.message.reply_text(help_text, parse_mode='Markdown')

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Status command handler - check connection status"""
    if not is_owner(update):
        await update.message.reply_text("⛔ Bot này chỉ phục vụ chủ sở hữu.")
        return
    import aiohttp

    status_message = "🔍 *Connection Status*\n\n"
    
    # Check Telegram connection
    status_message += "✅ Telegram Bot: Connected\n"
    
    # Check VS Code Server
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"{VSCODE_PUBLIC_URL}/", timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status == 200:
                    status_message += "✅ VS Code Server: Online\n"
                else:
                    status_message += f"⚠️  VS Code Server: Status {resp.status}\n"
    except Exception as e:
        status_message += f"❌ VS Code Server: Offline ({str(e)})\n"
    
    # Configuration
    status_message += f"\n*Configuration:*\n"
    status_message += f"VS Code URL: {VSCODE_PUBLIC_URL}\n"
    status_message += f"Bot Token: {TELEGRAM_BOT_TOKEN[:10]}...\n"
    
    await update.message.reply_text(status_message, parse_mode='Markdown')

async def info_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Info command - show project information"""
    if not is_owner(update):
        await update.message.reply_text("⛔ Bot này chỉ phục vụ chủ sở hữu.")
        return
    info_text = (
        "ℹ️ *VS Code Mini App*\n\n"
        "📌 Project: Telegram Mini App for VS Code Control\n"
        "🔗 Access VS Code from your phone via Telegram\n"
        "🤖 Integrated with Claude AI for coding assistance\n\n"
        "*Current Setup:*\n"
        f"• VS Code: {VSCODE_PUBLIC_URL}\n"
        f"• Bot Token: Configured ✅\n\n"
        "Type /help for more information."
    )
    
    await update.message.reply_text(info_text, parse_mode='Markdown')

async def file_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Nhận file gửi trong chat (ảnh nén qua message.photo HOẶC file gốc/mọi định
    dạng qua message.document — Telegram tách 2 kiểu này) và tự lưu vào
    FILE_INBOX_DIR trên máy chạy bot.py — cách để đồng bộ file từ điện thoại về
    máy tính khi làm việc từ xa qua telecode, không cần cài thêm app đồng bộ riêng.
    Ảnh gửi kiểu "Photo" (nén, mất EXIF/chất lượng gốc) chỉ có tối đa độ phân giải
    Telegram nén sẵn — muốn giữ nguyên file gốc, gửi kiểu "File"/"Document" trên
    Telegram thay vì chọn ảnh qua khung chat thường."""
    if not is_owner(update):
        await update.message.reply_text("⛔ Bot này chỉ phục vụ chủ sở hữu.")
        return

    message = update.message
    if message.document:
        tg_file_id = message.document.file_id
        original_name = message.document.file_name or message.document.file_unique_id
        suffix = ""
    elif message.photo:
        photo = message.photo[-1]  # phần tử cuối cùng = độ phân giải cao nhất
        tg_file_id = photo.file_id
        original_name = photo.file_unique_id
        suffix = ".jpg"
    else:
        return

    try:
        file = await context.bot.get_file(tg_file_id)
        dest_dir = Path(FILE_INBOX_DIR)
        dest_dir.mkdir(parents=True, exist_ok=True)
        filename = f"{datetime.now():%Y%m%d-%H%M%S}-{original_name}{suffix}"
        dest_path = dest_dir / filename
        await file.download_to_drive(str(dest_path))
        logger.info(f"📥 Đã lưu file từ Telegram: {dest_path}")
        await update.message.reply_text(f"✅ Đã lưu file vào: {dest_path}")
    except Exception as e:
        logger.error(f"❌ Lỗi lưu file: {e}")
        await update.message.reply_text(f"❌ Lỗi khi lưu file: {e}")


async def post_init(application: Application) -> None:
    # MenuButtonWebApp trỏ 1 URL TĨNH — chỉ set được khi biết chắc CHỈ 1 máy
    # online lúc bot khởi động (health-check qua discover_alive_servers(), dùng
    # chung logic với start()). Nếu ≥2 máy online cùng lúc (multi-server) hoặc
    # chưa máy nào online, không đại diện được bằng 1 icon tĩnh -> fallback về
    # menu danh sách lệnh, /start vẫn luôn là điểm vào đúng-mọi-lúc. Vì URL có
    # thể đổi máy nào đang online sau khi bot đã chạy, icon menu chỉ phản ánh
    # đúng trạng thái tại THỜI ĐIỂM bot khởi động — nếu server đổi, /start vẫn
    # trả đúng, chỉ icon menu không tự cập nhật cho tới lần bot restart kế tiếp.
    alive = await discover_alive_servers()
    if len(alive) == 1:
        name, url = alive[0]
        await application.bot.set_chat_menu_button(
            menu_button=MenuButtonWebApp(text="🔧 VS Code", web_app=WebAppInfo(url=url))
        )
        logger.info(f"✅ Đã đặt menu button mở thẳng {name} ({url})")
    else:
        await application.bot.set_chat_menu_button(menu_button=MenuButtonCommands())
        logger.info(f"✅ Đã đặt menu button dạng danh sách lệnh ({len(alive)} máy online, /start là điểm vào chính)")

def main() -> None:
    """Start the bot."""
    # Create the Application
    application = Application.builder().token(TELEGRAM_BOT_TOKEN).post_init(post_init).build()

    # Register command handlers
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("status", status_command))
    application.add_handler(CommandHandler("info", info_command))
    application.add_handler(CommandHandler("backup_configs", backup_configs_command))
    application.add_handler(MessageHandler(filters.PHOTO | filters.Document.ALL, file_handler))

    # Log bot info
    logger.info("="*50)
    logger.info("🤖 Telegram VS Code Mini App Bot")
    logger.info("="*50)
    logger.info("✅ Bot started successfully!")
    logger.info(f"🔗 VS Code URL: {VSCODE_PUBLIC_URL}")
    logger.info("📨 Waiting for messages...")
    logger.info("💡 Send /start to your bot on Telegram")
    logger.info("="*50)
    
    # Run the bot until the user presses Ctrl-C
    application.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == '__main__':
    main()

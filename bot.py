#!/usr/bin/env python3
"""
Telegram VS Code Mini App Bot
Allows users to open VS Code from Telegram via Web App
"""

import os
import logging
import yaml
from pathlib import Path
from telegram import Update, WebAppInfo, MenuButtonWebApp
from telegram.ext import Application, CommandHandler, ContextTypes

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = Path(__file__).parent / "config.yaml"
ENV_FILE = Path(__file__).parent / ".env"

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

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Start command handler — nút mở VS Code nằm ở menu button cạnh khung nhập tin nhắn (xem post_init)."""
    user = update.message.from_user
    logger.info(f"👤 User started bot: {user.first_name} (@{user.username})")

    welcome_message = (
        "🚀 *VS Code Remote Control*\n\n"
        "Bấm nút 🔧 cạnh khung nhập tin nhắn để mở VS Code từ điện thoại!\n\n"
        "✨ Features:\n"
        "• Full VS Code interface\n"
        "• Use Claude for coding assistance\n"
        "• Edit files remotely\n"
        "• Run terminal commands\n\n"
        "ℹ️ Make sure your computer is running VS Code Server."
    )

    await update.message.reply_text(welcome_message, parse_mode='Markdown')

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Help command handler"""
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

async def post_init(application: Application) -> None:
    # Đặt nút menu cố định cạnh khung nhập tin nhắn Telegram (áp dụng mặc định cho
    # mọi chat với bot) — không cần cấu hình qua BotFather. Bot API không cho icon
    # ảnh tuỳ chỉnh ở nút này, chỉ text ngắn.
    await application.bot.set_chat_menu_button(
        menu_button=MenuButtonWebApp(text="🔧 VS Code", web_app=WebAppInfo(url=VSCODE_PUBLIC_URL))
    )
    logger.info("✅ Đã đặt menu button 'VS Code' cạnh khung nhập tin nhắn")

def main() -> None:
    """Start the bot."""
    # Create the Application
    application = Application.builder().token(TELEGRAM_BOT_TOKEN).post_init(post_init).build()

    # Register command handlers
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("status", status_command))
    application.add_handler(CommandHandler("info", info_command))
    
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

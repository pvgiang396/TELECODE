#!/bin/bash

# Telegram VS Code Mini App - Setup Script
# Automatically configures the project

set -e

echo "🚀 Telegram VS Code Mini App - Setup"
echo "======================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Python
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}❌ Python 3 is not installed${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
echo -e "${GREEN}✅ Python ${PYTHON_VERSION} found${NC}"

# Check pip
if ! command -v pip3 &> /dev/null; then
    echo -e "${RED}❌ pip3 is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ pip3 found${NC}"
echo ""

# Create config from template
if [ ! -f config.yaml ]; then
    echo "📝 Creating config.yaml..."
    cp config.example.yaml config.yaml
    echo -e "${YELLOW}⚠️  Please edit config.yaml with your settings${NC}"
else
    echo -e "${GREEN}✅ config.yaml already exists${NC}"
fi

# Create .env from template
if [ ! -f .env ]; then
    echo "📝 Creating .env..."
    cp .env.example .env
    echo -e "${YELLOW}⚠️  Please edit .env with your settings${NC}"
else
    echo -e "${GREEN}✅ .env already exists${NC}"
fi

echo ""

# Create virtual environment
if [ ! -d venv ]; then
    echo "🔧 Creating virtual environment..."
    python3 -m venv venv
    echo -e "${GREEN}✅ Virtual environment created${NC}"
else
    echo -e "${GREEN}✅ Virtual environment already exists${NC}"
fi

echo ""

# Activate virtual environment
echo "🔌 Activating virtual environment..."
source venv/bin/activate

# Upgrade pip
echo "📦 Upgrading pip..."
pip install --upgrade pip setuptools wheel > /dev/null 2>&1

# Install requirements
echo "📦 Installing dependencies..."
pip install -r requirements.txt

echo ""
echo -e "${GREEN}✅ Dependencies installed${NC}"
echo ""

# Create workspace directory for Docker
if [ ! -d workspace ]; then
    mkdir -p workspace
    echo -e "${GREEN}✅ Created workspace directory${NC}"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ Setup Complete!${NC}"
echo "======================================"
echo ""
echo "📋 Next Steps:"
echo ""
echo "1. Edit configuration files:"
echo "   nano config.yaml     # Your settings"
echo "   nano .env           # Environment variables"
echo ""
echo "2. Setup code-server:"
echo "   # Option A: Use code-server"
echo "   sudo apt install code-server  # Linux"
echo "   brew install code-server      # macOS"
echo ""
echo "3. Create tunnel:"
echo "   # Install cloudflared"
echo "   # Then run: cloudflared tunnel --url http://localhost:8443"
echo ""
echo "4. Run the bot:"
echo "   python bot.py"
echo ""
echo "5. Or use Docker:"
echo "   docker-compose up -d"
echo ""
echo "📚 For more info, see README.md"
echo ""

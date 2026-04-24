#!/bin/bash
# ============================================
#  Установка системных зависимостей на Astra Linux 1.8
#  Запускать с sudo: sudo ./install_deps.sh
# ============================================
set -euo pipefail

echo "============================================"
echo " Installing dependencies for Astra Linux 1.8"
echo "============================================"
echo ""

apt-get update

# Базовые инструменты сборки
apt-get install -y \
    build-essential \
    cmake \
    python3 \
    python3-pip \
    python3-venv \
    git

echo ""
echo "[OK] Dependencies installed"
echo ""
echo "GCC:    $(gcc --version | head -1)"
echo "CMake:  $(cmake --version | head -1)"
echo "Python: $(python3 --version)"
echo "Git:    $(git --version)"
echo ""
echo "Next step: ./setup.sh"

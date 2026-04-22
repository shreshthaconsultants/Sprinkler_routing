@echo off
title Sprinkler Routing Backend Server
color 0A

echo ============================================
echo   SPRINKLER ROUTING - FastAPI Backend
echo ============================================
echo.

:: Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found. Please install Python 3.9+
    pause
    exit /b 1
)

:: Go to backend folder
cd /d "%~dp0backend"

:: Install dependencies
echo [1/2] Installing dependencies...
pip install -r requirements.txt --quiet

echo [2/2] Starting FastAPI server on http://localhost:8000
echo.
echo Press Ctrl+C to stop the server.
echo ============================================
echo.

:: Start server
python -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload

pause

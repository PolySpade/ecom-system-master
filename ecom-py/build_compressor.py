"""
Build script for Bulk Video Compressor executable
Run: python build_compressor.py
"""
import subprocess
import sys
import os

def main():
    # Check if PyInstaller is installed
    try:
        import PyInstaller
        print(f"PyInstaller version: {PyInstaller.__version__}")
    except ImportError:
        print("PyInstaller not found. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])
        print("PyInstaller installed successfully.")

    # Build command
    script_dir = os.path.dirname(os.path.abspath(__file__))
    main_script = os.path.join(script_dir, "bulk_compressor.py")

    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--onefile",                    # Single executable file
        "--windowed",                   # No console window
        "--name", "BulkVideoCompressor",
        "--clean",                      # Clean cache before building
        main_script
    ]

    print("\nBuilding executable...")
    print(f"Command: {' '.join(cmd)}\n")

    result = subprocess.run(cmd, cwd=script_dir)

    if result.returncode == 0:
        exe_path = os.path.join(script_dir, "dist", "BulkVideoCompressor.exe")
        print(f"\n{'='*50}")
        print("BUILD SUCCESSFUL!")
        print(f"Executable: {exe_path}")
        print(f"{'='*50}")
    else:
        print("\nBuild failed!")
        sys.exit(1)


if __name__ == "__main__":
    main()

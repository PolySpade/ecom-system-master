#!/usr/bin/env python3
"""
Game Directory Scanner - Minimal Version
"""

import os
import csv

GAME_EXTENSIONS = {
    '.nes', '.snes', '.sfc', '.n64', '.z64', '.v64', '.nds', '.3ds', '.gba', '.gbc', '.gb',
    '.md', '.gen', '.sms', '.gg', '.32x', '.cdi',
    '.iso', '.bin', '.cue', '.pbp', '.chd',
    '.zip', '.7z',
    '.a26', '.a52', '.a78', '.lnx',
    '.pce', '.sgx', '.neo',
    '.rom', '.img', '.cso', '.rvz', '.wbfs', '.gcz', '.nsp', '.xci'
}


def scan(directory, output_file):
    """Scan directory and save to CSV."""
    print(f"Scanning: {directory}")
    
    # Open CSV file
    f = open(output_file, 'w', newline='', encoding='utf-8', errors='ignore')
    writer = csv.writer(f)
    writer.writerow(['filename', 'extension', 'full_filename', 'folder', 'size_mb'])
    
    count = 0
    
    # Get list of folders (root + subfolders)
    folders = [directory]
    try:
        for item in os.listdir(directory):
            full_path = os.path.join(directory, item)
            if os.path.isdir(full_path):
                folders.append(full_path)
    except:
        pass
    
    print(f"Folders to scan: {len(folders)}")
    
    # Scan each folder
    for folder in folders:
        folder_name = os.path.basename(folder) if folder != directory else ''
        
        try:
            files = os.listdir(folder)
        except:
            continue
        
        for filename in files:
            try:
                filepath = os.path.join(folder, filename)
                
                if not os.path.isfile(filepath):
                    continue
                
                # Get extension
                _, ext = os.path.splitext(filename)
                ext = ext.lower()
                
                if ext not in GAME_EXTENSIONS:
                    continue
                
                # Get size
                try:
                    size_mb = round(os.path.getsize(filepath) / (1024 * 1024), 2)
                except:
                    size_mb = 0
                
                # Get name without extension
                name = os.path.splitext(filename)[0]
                
                # Write to CSV
                writer.writerow([name, ext, filename, folder_name, size_mb])
                count += 1
                
            except:
                continue
    
    f.close()
    print(f"Done! Found {count} games. Saved to: {output_file}")
    return count


def compare(smaller_csv, bigger_csv):
    """Compare two CSV files."""
    print(f"Loading: {bigger_csv}")
    
    # Load bigger collection names into a set
    bigger_names = set()
    with open(bigger_csv, 'r', encoding='utf-8', errors='ignore') as f:
        reader = csv.reader(f)
        next(reader)  # skip header
        for row in reader:
            if row:
                bigger_names.add(row[0].lower())  # filename column
    
    print(f"  -> {len(bigger_names)} games")
    print(f"Comparing with: {smaller_csv}")
    
    # Compare - group by folder
    missing_by_folder = {}
    found = 0
    total = 0
    
    with open(smaller_csv, 'r', encoding='utf-8', errors='ignore') as f:
        reader = csv.reader(f)
        next(reader)  # skip header
        for row in reader:
            if row:
                total += 1
                name = row[0].lower()
                full_filename = row[2]
                folder = row[3] if row[3] else "(root)"
                
                if name in bigger_names:
                    found += 1
                else:
                    if folder not in missing_by_folder:
                        missing_by_folder[folder] = []
                    missing_by_folder[folder].append(full_filename)
    
    # Count total missing
    total_missing = sum(len(games) for games in missing_by_folder.values())
    
    # Results
    print("\n" + "=" * 50)
    print("RESULTS")
    print("=" * 50)
    print(f"Total in smaller: {total}")
    print(f"Found in both: {found}")
    print(f"Missing: {total_missing}")
    print("=" * 50)
    
    if missing_by_folder:
        # Save missing to file, grouped by folder
        with open('missing_games.txt', 'w', encoding='utf-8') as f:
            f.write("MISSING GAMES BY SYSTEM\n")
            f.write("=" * 50 + "\n\n")
            
            # Sort folders alphabetically
            for folder in sorted(missing_by_folder.keys()):
                games = missing_by_folder[folder]
                f.write(f"\n{'=' * 50}\n")
                f.write(f"{folder} ({len(games)} missing)\n")
                f.write(f"{'=' * 50}\n")
                for game in sorted(games):
                    f.write(f"  {game}\n")
        
        print(f"\nMissing games saved to: missing_games.txt")
        
        # Show summary by folder
        print("\nMissing by system:")
        print("-" * 30)
        for folder in sorted(missing_by_folder.keys()):
            count = len(missing_by_folder[folder])
            print(f"  {folder}: {count}")
        print("-" * 30)
        print(f"  TOTAL: {total_missing}")


def main():
    print("\n" + "=" * 50)
    print("GAME SCANNER")
    print("=" * 50)
    print("\n1. Scan directory")
    print("2. Compare collections")
    print("3. Exit")
    
    choice = input("\nChoice (1/2/3): ").strip()
    
    if choice == '1':
        directory = input("Directory path: ").strip().strip('"').strip("'")
        output = input("Output CSV (default: games.csv): ").strip() or "games.csv"
        scan(directory, output)
        
    elif choice == '2':
        smaller = input("Smaller CSV path: ").strip().strip('"').strip("'")
        bigger = input("Bigger CSV path: ").strip().strip('"').strip("'")
        compare(smaller, bigger)
    
    input("\nPress Enter to exit...")


if __name__ == '__main__':
    main()
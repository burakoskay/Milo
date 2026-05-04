import os
import sys

root_dir = "/Volumes/Internal HD/Developer/Milo"

def replace_in_file(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        new_content = content.replace("com.monomacaw.milo", "com.monomacaw.milo")
        new_content = new_content.replace("com.monomacaw.milo", "com.monomacaw.milo")
        new_content = new_content.replace("Milo", "Milo")
        new_content = new_content.replace("Milo", "Milo")
        new_content = new_content.replace("MILO", "MILO")
        new_content = new_content.replace("monomacaw", "monomacaw")
        
        if new_content != content:
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(new_content)
    except Exception as e:
        pass

def rename_all():
    # Phase 1: replace text in files
    for root, dirs, files in os.walk(root_dir):
        if ".git" in root or ".build" in root or ".claude" in root or "data/" in root:
            continue
        for file in files:
            if file == ".DS_Store" or file.endswith((".swiftdoc", ".swiftmodule", ".o", ".dia", ".d", ".icns", ".png", ".dmg")):
                continue
            replace_in_file(os.path.join(root, file))

    # Phase 2: rename files and directories bottom up
    for root, dirs, files in os.walk(root_dir, topdown=False):
        if ".git" in root or ".build" in root or ".claude" in root or "data/" in root:
            continue
        
        for name in files:
            if "Milo" in name or "Milo" in name:
                new_name = name.replace("Milo", "Milo").replace("Milo", "Milo")
                os.rename(os.path.join(root, name), os.path.join(root, new_name))
                
        for name in dirs:
            if "Milo" in name or "Milo" in name:
                new_name = name.replace("Milo", "Milo").replace("Milo", "Milo")
                os.rename(os.path.join(root, name), os.path.join(root, new_name))

if __name__ == "__main__":
    rename_all()

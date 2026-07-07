import os
import shutil
import glob

source_dir = os.path.expanduser("~/Downloads")
dest_dir = "assets/images"

# Get all png files in Downloads
files = glob.glob(os.path.join(source_dir, "*.png"))
# Sort by modification time (newest first)
files.sort(key=os.path.getmtime, reverse=True)

# Take top 15
files_to_copy = files[:15]

print(f"Found {len(files_to_copy)} images.")

imported_files = []
for i, file_path in enumerate(files_to_copy):
    # New name
    new_name = f"custom_avatar_{i+1:02d}.png"
    dest_path = os.path.join(dest_dir, new_name)
    shutil.copy2(file_path, dest_path)
    imported_files.append(f"assets/images/{new_name}")
    print(f"Copied {file_path} to {dest_path}")

# Output list for Dart
print("\nDart List:")
for f in imported_files:
    print(f"    '{f}',")

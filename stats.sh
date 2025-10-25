#!/bin/bash

# Function to print section headers
print_header() {
  echo -e "\n--- $1 ---"
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to calculate diagonal in inches from mm dimensions (e.g., 344x193)
calculate_diagonal_inches() {
  local dimensions_mm=$1
  local width_mm=$(echo "$dimensions_mm" | cut -d'x' -f1)
  local height_mm=$(echo "$dimensions_mm" | cut -d'x' -f2)

  # Check if width_mm and height_mm are positive numbers
  # Added check for > 0 to avoid issues with 0mm x 0mm which xrandr sometimes reports
  if ! [[ "$width_mm" =~ ^[1-9][0-9]*$ ]] || ! [[ "$height_mm" =~ ^[1-9][0-9]*$ ]]; then
    echo "N/A"
    return
  fi

  # Calculate diagonal in mm using awk for floating point math
  local diag_mm=$(awk "BEGIN {printf \"%.0f\", sqrt($width_mm^2 + $height_mm^2)}")

  # Convert mm to inches and round to one decimal place
  local diag_in=$(awk "BEGIN {printf \"%.1f\", $diag_mm / 25.4}")
  echo "${diag_in}in"
}

# --- Device Info ---
print_header "Device Info"
if [[ -f /sys/class/dmi/id/product_name ]]; then
  echo "Model: $(cat /sys/class/dmi/id/product_name)"
else
  echo "Model: Not found"
fi

# Assuming the script is run with sudo, directly read the serial
if [[ -r /sys/class/dmi/id/product_serial ]]; then
  echo "Serial: $(cat /sys/class/dmi/id/product_serial)"
else
  echo "Serial: Not found or requires root" # Keep this message just in case
fi

# --- CPU ---
print_header "CPU"
# Use awk for cleaner output, fall back to grep
awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo || grep "model name" /proc/cpuinfo | uniq

# --- RAM ---
print_header "RAM"
if command_exists free; then
  # Show only GB (powers of 1000)
  echo "Reported by 'free' (GB):"
  free --si -h # Manufacturer GB
else
  echo "'free' command not found. Checking /proc/meminfo..."
  grep MemTotal /proc/meminfo
fi

# Check physical RAM with dmidecode if available
if command_exists dmidecode; then
  echo "Physical RAM (from dmidecode):"
  # Try to sum up the sizes reported by dmidecode
  total_ram_mb=$(dmidecode -t memory | awk '/Size: [0-9]+ MB/{sum+=$2} END{print sum}') # Removed sudo, assuming script runs as root
  if [[ "$total_ram_mb" -gt 0 ]]; then
    total_ram_gb=$(awk "BEGIN {printf \"%.1f GB\", $total_ram_mb / 1000}")
    echo "  Total Physical: $total_ram_gb"
  else
    # Fallback to listing individual modules if summing fails
    dmidecode -t memory | grep -i size | grep -vE 'No Module|Not Specified|Error:' || echo "  Could not read physical RAM details." # Removed sudo
  fi
else
  echo "'dmidecode' not found, cannot read physical RAM details."
fi

# --- Storage ---
print_header "Storage"
if command_exists lsblk; then
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
else
  echo "'lsblk' command not found."
fi

# --- GPU ---
print_header "GPU"
if command_exists lspci; then
  # Get GPU model
  lspci | grep -i 'vga\|3d'
  # Attempt to get kernel driver in use
  echo "Kernel driver in use:"
  lspci -k | grep -A 2 -i 'vga\|3d' | grep -i 'kernel driver' || echo "  Could not determine driver."
else
  echo "'lspci' command not found."
fi

# --- Screen ---
print_header "Screen"
if command_exists xrandr && xrandr_output=$(xrandr --current 2>/dev/null); then
  echo "Detected via xrandr:"
  # Process each connected line
  while IFS= read -r line; do
    # Quoted the regex pattern, removed 'local'
    if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+connected[[:space:]]+(primary[[:space:]]+)?([0-9]+x[0-9]+)\+[0-9]+\+[0-9]+.*[[:space:]]([1-9][0-9]*)mm[[:space:]]+x[[:space:]]+([1-9][0-9]*)mm ]]; then
      display_name="${BASH_REMATCH[1]}"
      resolution="${BASH_REMATCH[3]}" # Adjusted index due to optional (primary) group
      width_mm="${BASH_REMATCH[4]}"   # Adjusted index
      height_mm="${BASH_REMATCH[5]}"  # Adjusted index
      diagonal_in=$(calculate_diagonal_inches "${width_mm}x${height_mm}")
      echo "$display_name: ${resolution}, ${diagonal_in}"
    # Quoted the regex pattern, removed 'local'
    elif [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+connected[[:space:]]+(primary[[:space:]]+)?([0-9]+x[0-9]+)\+ ]]; then
      # Handle cases where physical size might be missing (0mm x 0mm or absent)
      display_name="${BASH_REMATCH[1]}"
      resolution="${BASH_REMATCH[3]}" # Adjusted index
      echo "$display_name: ${resolution}, Size N/A"
    fi
  done <<<"$(echo "$xrandr_output" | grep " connected")"
else
  echo "xrandr not available or no active X session found."
  # Fallback: Try reading EDID directly if possible (might need edid-decode)
  if command_exists edid-decode && ls /sys/class/drm/card*-*/*edid* 1>/dev/null 2>&1; then
    echo "Attempting to read EDID:"
    for edid_file in /sys/class/drm/card*-*/*edid*; do
      if [[ -f "$edid_file" && -r "$edid_file" ]]; then
        display_name=$(basename $(dirname "$edid_file")) # Keep local here, it's fine
        echo "--- EDID for $display_name ---"
        # Extract resolution (usually preferred timing) and size
        edid_info=$(edid-decode <"$edid_file") # Keep local here
        # Try getting preferred mode first, fallback to first mode listed if not found
        preferred_res=$(echo "$edid_info" | awk '/Preferred mode:/ {print $NF; exit}') # Keep local here
        [[ -z "$preferred_res" ]] && preferred_res=$(echo "$edid_info" | awk '/Mode:/ {print $NF; exit}')

        image_size_cm=$(echo "$edid_info" | awk -F': ' '/Image Size:/ {print $2}' | sed 's/ cm.*//') # Keep local here

        if [[ -n "$image_size_cm" && "$image_size_cm" =~ ([0-9]+)\ x\ ([0-9]+) ]]; then
          width_cm=${BASH_REMATCH[1]}                                           # Keep local here
          height_cm=${BASH_REMATCH[2]}                                          # Keep local here
          diagonal_in=$(calculate_diagonal_inches "${width_cm}0x${height_cm}0") # Convert cm to mm for calc function, keep local
          echo "  Resolution (Detected): $preferred_res"
          echo "  Size (from EDID): ${diagonal_in}"
        else
          echo "  Resolution (Detected): $preferred_res"
          echo "  Could not parse physical size from EDID."
        fi
        echo
      fi
    done
  else
    echo "Could not read EDID data (edid-decode not found or no EDID files in /sys)."
  fi
fi

# --- Battery ---
print_header "Battery"
# Prefer upower if available
if command_exists upower; then
  battery_path=$(upower -e | grep 'battery')
  if [[ -n "$battery_path" ]]; then
    echo "Using upower:"
    # Ensure only one battery path is processed if multiple are listed
    first_battery_path=$(echo "$battery_path" | head -n 1)
    upower -i "$first_battery_path" | grep -E 'state:|percentage:|capacity:'
  else
    echo "upower found, but no battery detected."
    # Fallback to sysfs if upower finds no battery
    found_sysfs_batt=false
    for bat_dir in /sys/class/power_supply/BAT*; do
      if [[ -d "$bat_dir" ]]; then
        echo "Trying fallback to /sys/class/power_supply:"
        echo "  Status: $(cat "$bat_dir/status" 2>/dev/null || echo N/A)"
        echo "  Capacity: $(cat "$bat_dir/capacity" 2>/dev/null || echo N/A)%"
        found_sysfs_batt=true
        break # Show first battery found
      fi
    done
    [[ "$found_sysfs_batt" = false ]] && echo "No battery found in /sys/class/power_supply either."
  fi
# Fallback to sysfs if upower command doesn't exist
elif ls /sys/class/power_supply/BAT* 1>/dev/null 2>&1; then
  echo "upower not found. Using /sys/class/power_supply:"
  for bat_dir in /sys/class/power_supply/BAT*; do
    if [[ -d "$bat_dir" ]]; then
      echo "  Status: $(cat "$bat_dir/status" 2>/dev/null || echo N/A)"
      echo "  Capacity: $(cat "$bat_dir/capacity" 2>/dev/null || echo N/A)%"
      break # Show first battery found
    fi
  done
else
  echo "upower not found and no battery detected in /sys/class/power_supply."
fi

echo # Final newline

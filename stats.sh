#!/bin/bash

# Function to print section headers
print_header() {
  echo -e "\n--- $1 ---"
}

# Ensure a package is installed on Arch (pacman); ignore errors if offline
ensure_pkg() {
  local pkg="$1"
  if ! command -v "$pkg" >/dev/null 2>&1; then
    if command -v pacman >/dev/null 2>&1; then
      # Try to refresh and install; ignore failures (e.g., no network)
      pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1 || true
    fi
  fi
}

# Check if fastfetch is available, ask user if they want to install it
if ! command -v fastfetch >/dev/null 2>&1; then
  if command -v pacman >/dev/null 2>&1; then
    echo "fastfetch is not installed."
    echo -n "Do you want to install fastfetch? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
      echo "Installing fastfetch..."
      ensure_pkg fastfetch
    else
      echo "Skipping fastfetch installation. Will use system files instead."
    fi
  fi
fi

# Try to make jq available (needed for parsing fastfetch JSON)
ensure_pkg jq

# Cache fastfetch JSON output if available
FF_JSON=""
if command -v fastfetch >/dev/null 2>&1; then
  # --logo none to reduce noise; ignore errors
  FF_JSON=$(fastfetch --logo none --json 2>/dev/null || echo "")
fi

# Helper to safely extract a value from fastfetch JSON using jq
ff_jq() {
  local query="$1"
  if [[ -n "$FF_JSON" ]] && command -v jq >/dev/null 2>&1; then
    echo "$FF_JSON" | jq -r "$query // empty" 2>/dev/null | sed -n '1p'
  fi
}

# --- Summary (Requested Info) ---
print_header "Requested Info"

# Device model
device_model=""
device_model=$(ff_jq '.host.productName')
if [[ -z "$device_model" && -r /sys/class/dmi/id/product_name ]]; then
  device_model=$(cat /sys/class/dmi/id/product_name)
fi
[[ -z "$device_model" ]] && device_model="N/A"
echo "Device model: $device_model"

# Serial number / serial tag
serial_tag=""
serial_tag=$(ff_jq '.host.productSerial')
if [[ -z "$serial_tag" && -r /sys/class/dmi/id/product_serial ]]; then
  serial_tag=$(cat /sys/class/dmi/id/product_serial)
fi
[[ -z "$serial_tag" ]] && serial_tag="N/A"
echo "Serial number/serial tag: $serial_tag"

# CPU manufacturer and full model
cpu_model_ff="$(ff_jq '.cpu.name')"
cpu_vendor_ff="$(ff_jq '.cpu.vendor')"

cpu_model=""
cpu_manufacturer=""

if [[ -n "$cpu_model_ff" ]]; then
  cpu_model="$cpu_model_ff"
else
  cpu_model=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
fi

if [[ -n "$cpu_vendor_ff" ]]; then
  cpu_manufacturer="$cpu_vendor_ff"
else
  # Prefer vendor_id mapping; fallback to first word of model name
  vend=$(awk -F':\t' '/vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  case "$vend" in
    GenuineIntel) cpu_manufacturer="Intel" ;;
    AuthenticAMD) cpu_manufacturer="AMD" ;;
    *) cpu_manufacturer="" ;;
  esac
  if [[ -z "$cpu_manufacturer" && -n "$cpu_model" ]]; then
    cpu_manufacturer="$(echo "$cpu_model" | awk '{print $1}')"
  fi
fi

[[ -z "$cpu_model" ]] && cpu_model="N/A"
[[ -z "$cpu_manufacturer" ]] && cpu_manufacturer="N/A"
echo "CPU manufacturer: $cpu_manufacturer"
echo "Full CPU model: $cpu_model"

# RAM (in GB, decimal 1000-base)
ram_gb=""
if command -v free >/dev/null 2>&1; then
  # Use MemTotal from /proc/meminfo for a stable numeric GB
  mem_kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    ram_gb=$(awk -v kb="$mem_kb" 'BEGIN {printf "%.1f", (kb*1000)/1e9}')
  fi
fi
[[ -z "$ram_gb" ]] && ram_gb="N/A"
echo "RAM (GB): $ram_gb"

# Storage: type (SSD/HDD) and size (GB) from first non-removable disk
storage_type="N/A"
storage_size_gb="N/A"
if command -v lsblk >/dev/null 2>&1; then
  # Get largest non-removable disk (exclude loop/rom)
  # Name, Rotational, SizeBytes
  read -r name rota size_bytes < <(lsblk -bdno NAME,ROTA,SIZE,TYPE,RM 2>/dev/null | awk '$4=="disk" && $5==0 {print $1, $2, $3}' | sort -k3,3nr | head -n1)
  if [[ -n "$name" ]]; then
    if [[ "$rota" == "0" ]]; then storage_type="SSD"; else storage_type="HDD"; fi
    if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
      storage_size_gb=$(awk -v b="$size_bytes" 'BEGIN {printf "%.1f", b/1e9}')
    fi
  fi
fi
echo "Storage type: $storage_type"
echo "Storage size (GB): $storage_size_gb"

# GPU maker
gpu_maker=""
gpu_maker=$(ff_jq '.gpu[0].vendor')
if [[ -z "$gpu_maker" ]]; then
  if command -v lspci >/dev/null 2>&1; then
    line=$(lspci | grep -iE 'vga|3d|display' | head -n1)
    if echo "$line" | grep -qi nvidia; then gpu_maker="NVIDIA"; fi
    if echo "$line" | grep -qi amd\|ati; then gpu_maker="AMD"; fi
    if echo "$line" | grep -qi intel; then gpu_maker="Intel"; fi
  fi
fi
[[ -z "$gpu_maker" ]] && gpu_maker="N/A"
echo "GPU maker: $gpu_maker"

# Battery (design/current capacity in mAh, health %)
batt_design_mah="N/A"
batt_current_mah="N/A"
batt_health_pct="N/A"

for bat_dir in /sys/class/power_supply/BAT*; do
  if [[ -d "$bat_dir" ]]; then
    if [[ -r "$bat_dir/charge_full_design" && -r "$bat_dir/charge_full" ]]; then
      # Units: µAh
      cfd=$(cat "$bat_dir/charge_full_design" 2>/dev/null)
      cf=$(cat "$bat_dir/charge_full" 2>/dev/null)
      cn=$(cat "$bat_dir/charge_now" 2>/dev/null || echo "")
      if [[ "$cfd" =~ ^[0-9]+$ ]]; then batt_design_mah=$(awk -v u="$cfd" 'BEGIN {printf "%.0f", u/1000}'); fi
      if [[ "$cn" =~ ^[0-9]+$ ]]; then batt_current_mah=$(awk -v u="$cn" 'BEGIN {printf "%.0f", u/1000}'); fi
      if [[ "$cf" =~ ^[0-9]+$ && "$cfd" =~ ^[0-9]+$ && $cfd -gt 0 ]]; then batt_health_pct=$(awk -v a="$cf" -v b="$cfd" 'BEGIN {printf "%.0f", (a/b)*100}'); fi
      break
    elif [[ -r "$bat_dir/energy_full_design" && -r "$bat_dir/energy_full" ]]; then
      # Units: µWh; convert to mAh if voltage_now (µV) available
      efd=$(cat "$bat_dir/energy_full_design" 2>/dev/null)
      ef=$(cat "$bat_dir/energy_full" 2>/dev/null)
      en=$(cat "$bat_dir/energy_now" 2>/dev/null || echo "")
      uv=$(cat "$bat_dir/voltage_now" 2>/dev/null || echo "")
      if [[ "$uv" =~ ^[0-9]+$ && $uv -gt 0 ]]; then
        if [[ "$efd" =~ ^[0-9]+$ ]]; then batt_design_mah=$(awk -v uwh="$efd" -v uv="$uv" 'BEGIN {printf "%.0f", (uwh/(uv/1000000))/1000}'); fi
        if [[ "$en" =~ ^[0-9]+$ ]]; then batt_current_mah=$(awk -v uwh="$en" -v uv="$uv" 'BEGIN {printf "%.0f", (uwh/(uv/1000000))/1000}'); fi
      fi
      if [[ "$ef" =~ ^[0-9]+$ && "$efd" =~ ^[0-9]+$ && $efd -gt 0 ]]; then batt_health_pct=$(awk -v a="$ef" -v b="$efd" 'BEGIN {printf "%.0f", (a/b)*100}'); fi
      break
    fi
  fi
done

echo "Battery design capacity (mAh): $batt_design_mah"
echo "Battery current capacity (mAh): $batt_current_mah"
echo "Battery health (%): $batt_health_pct"

# Display resolution (e.g., 1920x1080) – prefer xrandr first
display_res="N/A"
if command -v xrandr >/dev/null 2>&1; then
  xr_out=$(xrandr --current 2>/dev/null | grep " connected" | head -n1)
  if [[ "$xr_out" =~ ([0-9]+x[0-9]+)\+ ]]; then
    display_res="${BASH_REMATCH[1]}"
  fi
fi
if [[ "$display_res" == "N/A" ]] && command -v edid-decode >/dev/null 2>&1; then
  for edid_file in /sys/class/drm/card*-*/*edid*; do
    if [[ -f "$edid_file" && -r "$edid_file" ]]; then
      pref=$(edid-decode <"$edid_file" 2>/dev/null | awk '/Preferred mode:/ {print $NF; exit}')
      if [[ -n "$pref" ]]; then display_res="$pref"; break; fi
    fi
  done
fi
echo "Display resolution: $display_res"

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

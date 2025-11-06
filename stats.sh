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

# Try to make jq available (Arch live ISO friendly)
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

echo # Final newline

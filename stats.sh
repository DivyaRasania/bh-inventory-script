#!/bin/bash

# Function to extract JSON field using jq (preferred) or awk/grep fallback
extract_json_field() {
  local json="$1"
  local path="$2"
  
  # Try jq first if available (more reliable)
  if command_exists jq; then
    echo "$json" | jq -r "$path // empty" 2>/dev/null | head -1
    return
  fi
  
  # Fallback to awk/grep parsing
  # Handle nested paths like "system.hostName"
  if [[ "$path" =~ \. ]]; then
    # Split path and extract nested value
    local field_name=$(echo "$path" | awk -F'.' '{print $NF}')
    local prefix=$(echo "$path" | sed "s/\.$field_name$//")
    
    # Try to find the nested object
    if [[ -n "$prefix" ]]; then
      # Extract the object containing the field
      local obj_match=$(echo "$json" | grep -o "\"$prefix\":{[^}]*\"$field_name\":[^,}]*" | head -1)
      if [[ -n "$obj_match" ]]; then
        echo "$obj_match" | grep -o "\"$field_name\":\"[^\"]*\"" | sed 's/.*:"\([^"]*\)".*/\1/' | head -1
        return
      fi
    fi
  fi
  
  # Simple field extraction
  local field_name="$path"
  echo "$json" | grep -o "\"$field_name\":\"[^\"]*\"" | sed 's/.*:"\([^"]*\)".*/\1/' | head -1
  
  # Also try numeric values
  if [[ -z "$(echo "$json" | grep -o "\"$field_name\":\"[^\"]*\"" | head -1)" ]]; then
    echo "$json" | grep -o "\"$field_name\":[0-9.]*" | sed 's/.*:\([0-9.]*\).*/\1/' | head -1
  fi
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to calculate diagonal in inches from mm dimensions
calculate_diagonal_inches() {
  local dimensions_mm=$1
  local width_mm=$(echo "$dimensions_mm" | cut -d'x' -f1)
  local height_mm=$(echo "$dimensions_mm" | cut -d'x' -f2)

  if ! [[ "$width_mm" =~ ^[1-9][0-9]*$ ]] || ! [[ "$height_mm" =~ ^[1-9][0-9]*$ ]]; then
    echo "N/A"
    return
  fi

  local diag_mm=$(awk "BEGIN {printf \"%.0f\", sqrt($width_mm^2 + $height_mm^2)}")
  local diag_in=$(awk "BEGIN {printf \"%.1f\", $diag_mm / 25.4}")
  echo "${diag_in}"
}

# Try to get data from fastfetch JSON first, then fallback to direct methods
FASTFETCH_JSON=""
if command_exists fastfetch; then
  FASTFETCH_JSON=$(fastfetch --json 2>/dev/null)
fi

# Initialize variables
COMPUTER_NAME=""
SERIAL_NUMBER=""
BRAND=""
CPU_MANUFACTURER=""
CPU_MODEL=""
RAM_GB=""
STORAGE_TYPE=""
STORAGE_SIZE_GB=""
GPU_TYPE=""
GPU_MAKER=""
SCREEN_SIZE_INCHES=""
BATTERY_DESIGN_CAPACITY=""
BATTERY_CURRENT_CAPACITY=""
BATTERY_HEALTH=""
DISPLAY_RESOLUTION=""

# --- Computer name/model ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  COMPUTER_NAME=$(extract_json_field "$FASTFETCH_JSON" "system.hostName" | head -1)
  [[ -z "$COMPUTER_NAME" ]] && COMPUTER_NAME=$(extract_json_field "$FASTFETCH_JSON" "system.productName" | head -1)
fi
[[ -z "$COMPUTER_NAME" ]] && [[ -f /sys/class/dmi/id/product_name ]] && COMPUTER_NAME=$(cat /sys/class/dmi/id/product_name)
[[ -z "$COMPUTER_NAME" ]] && COMPUTER_NAME="N/A"

# --- Serial number/Service tag ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  SERIAL_NUMBER=$(extract_json_field "$FASTFETCH_JSON" "system.serial" | head -1)
fi
[[ -z "$SERIAL_NUMBER" ]] && [[ -r /sys/class/dmi/id/product_serial ]] && SERIAL_NUMBER=$(cat /sys/class/dmi/id/product_serial)
[[ -z "$SERIAL_NUMBER" ]] && SERIAL_NUMBER="N/A"

# --- Brand/Manufacturer ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  BRAND=$(extract_json_field "$FASTFETCH_JSON" "system.manufacturer" | head -1)
fi
[[ -z "$BRAND" ]] && [[ -f /sys/class/dmi/id/sys_vendor ]] && BRAND=$(cat /sys/class/dmi/id/sys_vendor)
[[ -z "$BRAND" ]] && BRAND="N/A"

# --- CPU Manufacturer ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  CPU_MANUFACTURER=$(extract_json_field "$FASTFETCH_JSON" "cpu.manufacturer" | head -1)
fi
if [[ -z "$CPU_MANUFACTURER" ]]; then
  CPU_MODEL_FULL=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  if [[ "$CPU_MODEL_FULL" =~ ^[Ii]ntel ]]; then
    CPU_MANUFACTURER="Intel"
  elif [[ "$CPU_MODEL_FULL" =~ ^[Aa]MD ]] || [[ "$CPU_MODEL_FULL" =~ [Aa]MD ]]; then
    CPU_MANUFACTURER="AMD"
  elif [[ "$CPU_MODEL_FULL" =~ [Aa]pple ]]; then
    CPU_MANUFACTURER="Apple"
  else
    CPU_MANUFACTURER="N/A"
  fi
fi
[[ -z "$CPU_MANUFACTURER" ]] && CPU_MANUFACTURER="N/A"

# --- Exact CPU Model ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  CPU_MODEL=$(extract_json_field "$FASTFETCH_JSON" "cpu.name" | head -1)
fi
[[ -z "$CPU_MODEL" ]] && CPU_MODEL=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="N/A"

# --- RAM (in GB) ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    RAM_RAW=$(echo "$FASTFETCH_JSON" | jq -r '.memory.total // empty' 2>/dev/null)
  else
    RAM_RAW=$(extract_json_field "$FASTFETCH_JSON" "memory.total" | head -1)
  fi
  # Remove units if present and convert to GB number
  if [[ -n "$RAM_RAW" ]] && [[ "$RAM_RAW" != "null" ]]; then
    if [[ "$RAM_RAW" =~ ([0-9.]+)[Mm][Ii] ]]; then
      RAM_GB=$(awk "BEGIN {printf \"%.2f\", ${BASH_REMATCH[1]} / 1024}")
    elif [[ "$RAM_RAW" =~ ([0-9.]+)[Gg][Ii]? ]]; then
      RAM_GB="${BASH_REMATCH[1]}"
    elif [[ "$RAM_RAW" =~ ([0-9.]+)[Tt] ]]; then
      RAM_GB=$(awk "BEGIN {printf \"%.2f\", ${BASH_REMATCH[1]} * 1024}")
    elif [[ "$RAM_RAW" =~ ^[0-9.]+$ ]]; then
      # Assume it's already in GB if it's just a number
      RAM_GB="$RAM_RAW"
    fi
  fi
fi
if [[ -z "$RAM_GB" ]] || [[ "$RAM_GB" == "N/A" ]] || [[ "$RAM_GB" == "null" ]]; then
  if command_exists dmidecode; then
    total_ram_mb=$(dmidecode -t memory 2>/dev/null | awk '/Size: [0-9]+ MB/{sum+=$2} END{print sum}')
    [[ "$total_ram_mb" -gt 0 ]] && RAM_GB=$(awk "BEGIN {printf \"%.2f\", $total_ram_mb / 1000}")
  fi
fi
if [[ -z "$RAM_GB" ]] || [[ "$RAM_GB" == "null" ]]; then
  if [[ -r /proc/meminfo ]]; then
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    [[ -n "$mem_total_kb" ]] && RAM_GB=$(awk "BEGIN {printf \"%.2f\", $mem_total_kb / 1024 / 1024}")
  fi
fi
[[ -z "$RAM_GB" ]] && RAM_GB="N/A"

# --- Storage Type (SSD/HDD) and Size ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    STORAGE_TYPE=$(echo "$FASTFETCH_JSON" | jq -r '.disk[0].type // empty' 2>/dev/null)
    STORAGE_SIZE_GB=$(echo "$FASTFETCH_JSON" | jq -r '.disk[0].size // empty' 2>/dev/null)
  else
    # Try to get first disk using grep
    DISK_JSON=$(echo "$FASTFETCH_JSON" | grep -o '"disk":\[[^]]*\]' | head -1)
    if [[ -n "$DISK_JSON" ]]; then
      # Extract type from first disk
      STORAGE_TYPE=$(echo "$DISK_JSON" | grep -o '"type":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
      # Extract size from first disk
      STORAGE_SIZE_GB=$(echo "$DISK_JSON" | grep -o '"size":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
    fi
  fi
  # Convert size to GB number if needed
  if [[ -n "$STORAGE_SIZE_GB" ]] && [[ "$STORAGE_SIZE_GB" != "null" ]] && [[ "$STORAGE_SIZE_GB" != "N/A" ]]; then
    if [[ "$STORAGE_SIZE_GB" =~ ([0-9.]+)[Tt][Bb] ]]; then
      STORAGE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${BASH_REMATCH[1]} * 1024}")
    elif [[ "$STORAGE_SIZE_GB" =~ ([0-9.]+)[Gg][Bb] ]]; then
      STORAGE_SIZE_GB="${BASH_REMATCH[1]}"
    elif [[ "$STORAGE_SIZE_GB" =~ ([0-9.]+)[Mm][Bb] ]]; then
      STORAGE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", ${BASH_REMATCH[1]} / 1024}")
    fi
  fi
fi
if [[ -z "$STORAGE_TYPE" ]] || [[ "$STORAGE_TYPE" == "null" ]]; then
  # Try to detect from lsblk or /sys/block
  if command_exists lsblk; then
    # Get first disk device
    FIRST_DISK=$(lsblk -nd -o NAME,TYPE 2>/dev/null | awk '/disk/{print $1; exit}')
    if [[ -n "$FIRST_DISK" ]]; then
      # Check if it's a rotational disk
      if [[ -r /sys/block/$FIRST_DISK/queue/rotational ]]; then
        ROTATIONAL=$(cat /sys/block/$FIRST_DISK/queue/rotational 2>/dev/null)
        [[ "$ROTATIONAL" == "0" ]] && STORAGE_TYPE="SSD" || STORAGE_TYPE="HDD"
      fi
      # Get size
      if command_exists lsblk; then
        DISK_SIZE=$(lsblk -nd -o SIZE /dev/$FIRST_DISK 2>/dev/null | head -1)
        # Convert to GB
        if [[ "$DISK_SIZE" =~ ([0-9.]+)([TtGgMm]) ]]; then
          SIZE_VAL="${BASH_REMATCH[1]}"
          SIZE_UNIT="${BASH_REMATCH[2]}"
          case "${SIZE_UNIT^^}" in
            T) STORAGE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE_VAL * 1024}") ;;
            G) STORAGE_SIZE_GB="$SIZE_VAL" ;;
            M) STORAGE_SIZE_GB=$(awk "BEGIN {printf \"%.2f\", $SIZE_VAL / 1024}") ;;
          esac
        fi
      fi
    fi
  fi
fi
[[ -z "$STORAGE_TYPE" ]] && STORAGE_TYPE="N/A"
[[ -z "$STORAGE_SIZE_GB" ]] && STORAGE_SIZE_GB="N/A"

# --- GPU Type (Integrated/Dedicated) and Maker ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    GPU_TYPE=$(echo "$FASTFETCH_JSON" | jq -r '.gpu[0].type // empty' 2>/dev/null)
    GPU_MAKER=$(echo "$FASTFETCH_JSON" | jq -r '.gpu[0].vendor // empty' 2>/dev/null)
  else
    GPU_JSON=$(echo "$FASTFETCH_JSON" | grep -o '"gpu":\[[^]]*\]' | head -1)
    if [[ -n "$GPU_JSON" ]]; then
      GPU_TYPE=$(echo "$GPU_JSON" | grep -o '"type":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
      GPU_MAKER=$(echo "$GPU_JSON" | grep -o '"vendor":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
    fi
  fi
fi
if [[ -z "$GPU_TYPE" ]] || [[ "$GPU_TYPE" == "null" ]]; then
  if command_exists lspci; then
    GPU_INFO=$(lspci | grep -i 'vga\|3d\|display' | head -1)
    if [[ -n "$GPU_INFO" ]]; then
      # Detect if Intel (usually integrated) or NVIDIA/AMD (usually dedicated)
      if echo "$GPU_INFO" | grep -qi intel; then
        GPU_TYPE="Integrated"
        GPU_MAKER="Intel"
      elif echo "$GPU_INFO" | grep -qi nvidia; then
        GPU_TYPE="Dedicated"
        GPU_MAKER="NVIDIA"
      elif echo "$GPU_INFO" | grep -qi amd; then
        GPU_TYPE="Dedicated"
        GPU_MAKER="AMD"
      else
        # Check for multiple GPUs - if more than one, likely has dedicated
        GPU_COUNT=$(lspci | grep -i 'vga\|3d\|display' | wc -l)
        [[ $GPU_COUNT -gt 1 ]] && GPU_TYPE="Dedicated" || GPU_TYPE="Integrated"
        GPU_MAKER=$(echo "$GPU_INFO" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[A-Z]/) {print $i; exit}}')
      fi
    fi
  fi
fi
[[ -z "$GPU_TYPE" ]] && GPU_TYPE="N/A"
[[ -z "$GPU_MAKER" ]] && GPU_MAKER="N/A"

# --- Screen Size (in Inches) ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    SCREEN_SIZE_RAW=$(echo "$FASTFETCH_JSON" | jq -r '.display[0].size // empty' 2>/dev/null)
    SCREEN_SIZE_INCHES=$(echo "$SCREEN_SIZE_RAW" | sed 's/[^0-9.]//g')
  else
    DISPLAY_JSON=$(echo "$FASTFETCH_JSON" | grep -o '"display":\[[^]]*\]' | head -1)
    if [[ -n "$DISPLAY_JSON" ]]; then
      SCREEN_SIZE_INCHES=$(echo "$DISPLAY_JSON" | grep -o '"size":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/' | sed 's/[^0-9.]//g')
    fi
  fi
fi
if [[ -z "$SCREEN_SIZE_INCHES" ]] || [[ "$SCREEN_SIZE_INCHES" == "null" ]]; then
  # Try xrandr
  if command_exists xrandr && xrandr_output=$(xrandr --current 2>/dev/null); then
    while IFS= read -r line; do
      if [[ "$line" =~ connected.*([1-9][0-9]*)mm[[:space:]]+x[[:space:]]+([1-9][0-9]*)mm ]]; then
        width_mm="${BASH_REMATCH[1]}"
        height_mm="${BASH_REMATCH[2]}"
        SCREEN_SIZE_INCHES=$(calculate_diagonal_inches "${width_mm}x${height_mm}")
        break
      fi
    done <<<"$(echo "$xrandr_output" | grep " connected")"
  fi
  # Fallback to EDID
  if [[ -z "$SCREEN_SIZE_INCHES" ]] && command_exists edid-decode && ls /sys/class/drm/card*-*/*edid* 1>/dev/null 2>&1; then
    for edid_file in /sys/class/drm/card*-*/*edid*; do
      if [[ -f "$edid_file" && -r "$edid_file" ]]; then
        image_size_cm=$(edid-decode <"$edid_file" 2>/dev/null | awk -F': ' '/Image Size:/ {print $2}' | sed 's/ cm.*//')
        if [[ -n "$image_size_cm" && "$image_size_cm" =~ ([0-9]+)\ x\ ([0-9]+) ]]; then
          width_cm=${BASH_REMATCH[1]}
          height_cm=${BASH_REMATCH[2]}
          SCREEN_SIZE_INCHES=$(calculate_diagonal_inches "${width_cm}0x${height_cm}0")
          break
        fi
      fi
    done
  fi
fi
[[ -z "$SCREEN_SIZE_INCHES" ]] && SCREEN_SIZE_INCHES="N/A"

# --- Battery Design Capacity, Current Capacity, and Health ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    BATTERY_DESIGN_CAPACITY=$(echo "$FASTFETCH_JSON" | jq -r '.battery.designCapacity // empty' 2>/dev/null | grep -o '[0-9.]*' | head -1)
    BATTERY_CURRENT_CAPACITY=$(echo "$FASTFETCH_JSON" | jq -r '.battery.currentCapacity // empty' 2>/dev/null | grep -o '[0-9.]*' | head -1)
    BATTERY_HEALTH=$(echo "$FASTFETCH_JSON" | jq -r '.battery.health // empty' 2>/dev/null)
  else
    BATTERY_JSON=$(echo "$FASTFETCH_JSON" | grep -o '"battery":{[^}]*}' | head -1)
    if [[ -n "$BATTERY_JSON" ]]; then
      BATTERY_DESIGN_CAPACITY=$(echo "$BATTERY_JSON" | grep -o '"designCapacity":"[^"]*"' | sed 's/.*:"\([^"]*\)".*/\1/' | grep -o '[0-9.]*' | head -1)
      BATTERY_CURRENT_CAPACITY=$(echo "$BATTERY_JSON" | grep -o '"currentCapacity":"[^"]*"' | sed 's/.*:"\([^"]*\)".*/\1/' | grep -o '[0-9.]*' | head -1)
      BATTERY_HEALTH=$(echo "$BATTERY_JSON" | grep -o '"health":"[^"]*"' | sed 's/.*:"\([^"]*\)".*/\1/')
    fi
  fi
fi
if [[ -z "$BATTERY_DESIGN_CAPACITY" ]] || [[ "$BATTERY_DESIGN_CAPACITY" == "null" ]]; then
  # Try upower
  if command_exists upower; then
    battery_path=$(upower -e 2>/dev/null | grep 'battery' | head -1)
    if [[ -n "$battery_path" ]]; then
      battery_info=$(upower -i "$battery_path" 2>/dev/null)
      BATTERY_DESIGN_CAPACITY=$(echo "$battery_info" | grep -i "energy-full-design" | awk '{print $2*1000}' | cut -d. -f1)
      BATTERY_CURRENT_CAPACITY=$(echo "$battery_info" | grep -i "energy:" | awk '{print $2*1000}' | cut -d. -f1)
      # Battery health calculation
      if [[ -n "$BATTERY_DESIGN_CAPACITY" ]] && [[ -n "$BATTERY_CURRENT_CAPACITY" ]] && [[ "$BATTERY_DESIGN_CAPACITY" -gt 0 ]]; then
        health_percent=$(awk "BEGIN {printf \"%.0f\", ($BATTERY_CURRENT_CAPACITY / $BATTERY_DESIGN_CAPACITY) * 100}")
        if [[ $health_percent -ge 80 ]]; then
          BATTERY_HEALTH="Good"
        elif [[ $health_percent -ge 60 ]]; then
          BATTERY_HEALTH="Fair"
        else
          BATTERY_HEALTH="Poor"
        fi
      fi
    fi
  fi
  # Fallback to sysfs
  if [[ -z "$BATTERY_DESIGN_CAPACITY" ]] && ls /sys/class/power_supply/BAT* 1>/dev/null 2>&1; then
    for bat_dir in /sys/class/power_supply/BAT*; do
      if [[ -d "$bat_dir" ]]; then
        # Charge full design (mAh)
        charge_full_design=$(cat "$bat_dir/charge_full_design" 2>/dev/null)
        charge_full=$(cat "$bat_dir/charge_full" 2>/dev/null)
        charge_now=$(cat "$bat_dir/charge_now" 2>/dev/null)
        if [[ -n "$charge_full_design" ]] && [[ "$charge_full_design" -gt 0 ]]; then
          # Convert from microamp-hours to milliampere-hours if needed
          [[ "$charge_full_design" -gt 10000 ]] && BATTERY_DESIGN_CAPACITY=$((charge_full_design / 1000)) || BATTERY_DESIGN_CAPACITY=$charge_full_design
          [[ -n "$charge_now" ]] && [[ "$charge_now" -gt 0 ]] && {
            [[ "$charge_now" -gt 10000 ]] && BATTERY_CURRENT_CAPACITY=$((charge_now / 1000)) || BATTERY_CURRENT_CAPACITY=$charge_now
          }
          # Calculate health
          if [[ -n "$charge_full" ]] && [[ "$charge_full" -gt 0 ]] && [[ "$charge_full_design" -gt 0 ]]; then
            health_percent=$(awk "BEGIN {printf \"%.0f\", ($charge_full / $charge_full_design) * 100}")
            if [[ $health_percent -ge 80 ]]; then
              BATTERY_HEALTH="Good"
            elif [[ $health_percent -ge 60 ]]; then
              BATTERY_HEALTH="Fair"
            else
              BATTERY_HEALTH="Poor"
            fi
          fi
        fi
        break
      fi
    done
  fi
fi
[[ -z "$BATTERY_DESIGN_CAPACITY" ]] && BATTERY_DESIGN_CAPACITY="N/A"
[[ -z "$BATTERY_CURRENT_CAPACITY" ]] && BATTERY_CURRENT_CAPACITY="N/A"
[[ -z "$BATTERY_HEALTH" ]] && BATTERY_HEALTH="N/A"

# --- Display Resolution ---
if [[ -n "$FASTFETCH_JSON" ]]; then
  if command_exists jq; then
    DISPLAY_RESOLUTION=$(echo "$FASTFETCH_JSON" | jq -r '.display[0].resolution // empty' 2>/dev/null)
  else
    DISPLAY_JSON=$(echo "$FASTFETCH_JSON" | grep -o '"display":\[[^]]*\]' | head -1)
    if [[ -n "$DISPLAY_JSON" ]]; then
      DISPLAY_RESOLUTION=$(echo "$DISPLAY_JSON" | grep -o '"resolution":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
    fi
  fi
fi
if [[ -z "$DISPLAY_RESOLUTION" ]] || [[ "$DISPLAY_RESOLUTION" == "null" ]]; then
  if command_exists xrandr && xrandr_output=$(xrandr --current 2>/dev/null); then
    while IFS= read -r line; do
      if [[ "$line" =~ connected.*([0-9]+x[0-9]+)\+ ]]; then
        DISPLAY_RESOLUTION="${BASH_REMATCH[1]}"
        break
      fi
    done <<<"$(echo "$xrandr_output" | grep " connected")"
  fi
  # Fallback to EDID
  if [[ -z "$DISPLAY_RESOLUTION" ]] && command_exists edid-decode && ls /sys/class/drm/card*-*/*edid* 1>/dev/null 2>&1; then
    for edid_file in /sys/class/drm/card*-*/*edid*; do
      if [[ -f "$edid_file" && -r "$edid_file" ]]; then
        DISPLAY_RESOLUTION=$(edid-decode <"$edid_file" 2>/dev/null | awk '/Preferred mode:/ {print $NF; exit}')
        [[ -z "$DISPLAY_RESOLUTION" ]] && DISPLAY_RESOLUTION=$(edid-decode <"$edid_file" 2>/dev/null | awk '/Mode:/ {print $NF; exit}')
        [[ -n "$DISPLAY_RESOLUTION" ]] && break
      fi
    done
  fi
fi
[[ -z "$DISPLAY_RESOLUTION" ]] && DISPLAY_RESOLUTION="N/A"

# Output all collected information
echo "Computer name/model: $COMPUTER_NAME"
echo "Serial number/Service tag: $SERIAL_NUMBER"
echo "Brand/Manufacturer: $BRAND"
echo "CPU Manufacturer: $CPU_MANUFACTURER"
echo "Exact CPU model: $CPU_MODEL"
echo "RAM (in GB): $RAM_GB"
echo "Storage Type (SSD/HDD): $STORAGE_TYPE"
echo "Storage Size (in GB): $STORAGE_SIZE_GB"
echo "GPU Type (Integrated/Dedicated): $GPU_TYPE"
echo "GPU Maker: $GPU_MAKER"
echo "Screen Size (in Inches): $SCREEN_SIZE_INCHES"
echo "Battery Design Capacity (mAh): $BATTERY_DESIGN_CAPACITY"
echo "Battery Current Capacity (mAh): $BATTERY_CURRENT_CAPACITY"
echo "Battery Health: $BATTERY_HEALTH"
echo "Display Resolution: $DISPLAY_RESOLUTION"

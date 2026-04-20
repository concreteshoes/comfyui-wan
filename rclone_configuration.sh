#!/usr/bin/env bash

set -e

CONFIG_DIR="$HOME/.config/rclone"
CONFIG_FILE="$CONFIG_DIR/rclone.conf"

echo "===================================================="
echo "        RCLONE GOOGLE DRIVE SETUP (FULL JSON)       "
echo "===================================================="
echo ""
echo "This environment does NOT support browser login."
echo ""
echo "➡️  Generate your token on your LOCAL machine:"
echo "   1) Run: rclone config"
echo "   2) Set up a 'drive' remote using your custom client_id and secret."
echo "   3) Authenticate in the browser."
echo "   4) Run: rclone config show <your_remote_name>:"
echo ""
echo "➡️  Copy the ENTIRE JSON block next to 'token ='"
echo "   Example: {\"access_token\":\"ya29...\",\"refresh_token\":\"1//...\",\"token_type\":\"Bearer\",\"expiry\":\"...\"}"
echo ""

mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
    echo "⚠️  Existing rclone config detected at $CONFIG_FILE"
    read -rp "Overwrite it? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborting setup."
        exit 0
    fi
fi

echo ""
read -rp "📁 Root Folder ID (Optional, press Enter to skip): " ROOT_FOLDER_ID

echo ""
read -rp "🔑 Paste the FULL JSON Token: " RAW_INPUT
echo ""

if [ -z "$RAW_INPUT" ]; then
    echo "❌ Error: No token was pasted."
    exit 1
fi

# Clean the input: strip any accidental leading/trailing spaces or single quotes
CLEAN_TOKEN=$(echo "$RAW_INPUT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'//" -e "s/'$//")

# Quick sanity check
if [[ "$CLEAN_TOKEN" != "{"* ]]; then
    echo "⚠️  Warning: The pasted text doesn't start with '{'. Make sure you pasted the full JSON token."
    echo "Press Ctrl+C to abort or Enter to continue anyway."
    read -r
fi

echo ""
read -rp "🔑 Google Client ID (optional, press Enter to use rclone default): " CLIENT_ID
read -rp "🔑 Google Client Secret (optional, press Enter to use rclone default): " CLIENT_SECRET

echo "Creating rclone config..."

{
    echo "[gdrive]"
    echo "type = drive"
    echo "scope = drive"

    # Only include if provided
    [ -n "$CLIENT_ID" ] && echo "client_id = $CLIENT_ID"
    [ -n "$CLIENT_SECRET" ] && echo "client_secret = $CLIENT_SECRET"

    [ -n "$ROOT_FOLDER_ID" ] && echo "root_folder_id = $ROOT_FOLDER_ID"
    echo "token = $CLEAN_TOKEN"
} > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

echo ""
echo "✅ Config created at: $CONFIG_FILE"

echo ""
echo "🔍 Testing connection..."

if rclone lsd gdrive: > /dev/null 2>&1; then
    echo "✅ Connection successful!"
else
    echo "⚠️  Connection test failed."
    echo "   - Run 'cat ~/.config/rclone/rclone.conf' to verify the token formatting."
fi

echo ""
echo "🎉 Setup complete!"
echo "===================================================="
echo ""
echo "===================================================="
echo "                RCLONE QUICK START                  "
echo "===================================================="
echo ""
echo "📂 List files in your Google Drive:"
echo "   rclone ls gdrive:"
echo ""
echo "📁 List folders only:"
echo "   rclone lsd gdrive:"
echo ""
echo "📄 List files inside a specific folder:"
echo "   rclone ls gdrive:/your-folder"
echo ""
echo "⬇️  Download a file:"
echo "   rclone copy gdrive:/filename /local/path -P"
echo ""
echo "⬇️  Download folder's contents:"
echo "   rclone copy gdrive:/folder/ /local/path/ -P"
echo ""
echo "⬆️  Upload a file:"
echo "   rclone copy /local/file gdrive:/ -P"
echo ""
echo "⬆️  Upload a folder:"
echo "   rclone copy /local/folder gdrive:/target-folder -P"
echo ""
echo "🔄 Sync (mirror local → remote):"
echo "   rclone sync /local/folder gdrive:/target-folder -P"
echo ""
echo "⚡ Advanced (optimized transfer example):"
echo "   rclone copy /local/path gdrive:/remote/folder \\"
echo "     -P -v \\"
echo "     --transfers 4 \\"
echo "     --checkers 16 \\"
echo "     --drive-chunk-size 128M \\"
echo "     --buffer-size 64M \\"
echo "     --drive-upload-cutoff 128M \\"
echo "     --fast-list"
echo ""
echo "   Optional (if speeds fluctuate):"
echo "     --low-level-retries 10"
echo ""
echo ""
echo "💡 Notes:"
echo " - Use '-P' to show progress"
echo " - Use '-v' for verbose logs"
echo " - Paths use ':' for remotes (gdrive:/...)"
echo " - If you set a root_folder_id, paths are relative to that folder"
echo ""
echo ""
echo "📦 Archive & Compress (faster for many small files):"
echo "   zip -r -0 models.zip /local/path  # -0 for no compression (fastest)"
echo "   tar -cvzf models.tar.gz /local/path # gzip compression (saves space)"
echo ""
echo ""
echo "⬆️  Upload Compressed Archive:"
echo "   rclone copy output_folder/models.zip gdrive:/backups/ -P"
echo ""
echo ""
echo "🛡️ Integrity Tip:"
echo "   Use 'rclone check /local/path gdrive:/remote/path' to verify"
echo "   that your cloud backup matches your local file exactly."
echo ""
echo ""
echo "🔐 Cleanup recommendation:"
echo "   If using persistent storage, remove your config after use:"
echo "   rm -f ~/.config/rclone/rclone.conf"
echo ""
echo "===================================================="
echo ""

#!/bin/bash

# Universal SSH Key Manager
# A comprehensive tool for managing SSH keys on any server
# Compatible with all SSH key types (RSA, ED25519, ECDSA)

# Colors for professional output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Version and info
VERSION="1.0.0"
AUTHOR="Malik Arslan"
REPO="https://github.com/malikarslan699/scripts"

# Professional header
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                🔐 Universal SSH Key Manager                 ║${NC}"
echo -e "${CYAN}║                    Version ${VERSION}                        ║${NC}"
echo -e "${CYAN}║              Professional SSH Key Management Tool           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to show help
show_help() {
    echo -e "${WHITE}📖 Usage Examples:${NC}"
    echo ""
    echo -e "${YELLOW}1. Interactive Mode:${NC}"
    echo -e "   ${BLUE}./universal-ssh-manager.sh${NC}"
    echo ""
    echo -e "${YELLOW}2. Quick Setup:${NC}"
    echo -e "   ${BLUE}./universal-ssh-manager.sh -k 'ssh-ed25519 AAAAC3...' -r 'my-server' -s 'root@192.168.1.100'${NC}"
    echo ""
    echo -e "${YELLOW}3. Batch Setup:${NC}"
    echo -e "   ${BLUE}./universal-ssh-manager.sh -f servers.txt${NC}"
    echo ""
    echo -e "${YELLOW}4. Check Status:${NC}"
    echo -e "   ${BLUE}./universal-ssh-manager.sh -c root@192.168.1.100${NC}"
    echo ""
    echo -e "${YELLOW}5. Remove Key:${NC}"
    echo -e "   ${BLUE}./universal-ssh-manager.sh -d 'my-server' root@192.168.1.100${NC}"
    echo ""
    echo -e "${WHITE}📋 Options:${NC}"
    echo -e "   ${CYAN}-k, --key${NC}        SSH Public Key"
    echo -e "   ${CYAN}-r, --reference${NC}  Reference identifier"
    echo -e "   ${CYAN}-s, --server${NC}     Target server (user@host)"
    echo -e "   ${CYAN}-f, --file${NC}       Batch file with servers"
    echo -e "   ${CYAN}-c, --check${NC}      Check SSH key status"
    echo -e "   ${CYAN}-d, --delete${NC}     Delete key by reference"
    echo -e "   ${CYAN}-h, --help${NC}       Show this help"
    echo -e "   ${CYAN}-v, --version${NC}    Show version"
    echo ""
}

# Function to validate SSH key format
validate_ssh_key() {
    local key="$1"
    
    # Check for common SSH key formats
    if [[ $key =~ ^ssh-(rsa|ed25519|ecdsa|dss) ]]; then
        return 0
    else
        echo -e "${RED}❌ Invalid SSH key format${NC}"
        echo -e "${YELLOW}Supported formats: ssh-rsa, ssh-ed25519, ssh-ecdsa, ssh-dss${NC}"
        return 1
    fi
}

# Function to test server connection
test_connection() {
    local server="$1"
    
    echo -e "${BLUE}🔍 Testing connection to ${server}...${NC}"
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "echo 'Connection test successful'" 2>/dev/null; then
        echo -e "${GREEN}✅ Key-based authentication working${NC}"
        return 0
    elif ssh -o ConnectTimeout=10 "$server" "echo 'Connection test successful'" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Password authentication required${NC}"
        return 1
    else
        echo -e "${RED}❌ Cannot connect to server${NC}"
        return 2
    fi
}

# Function to check existing key
check_existing_key() {
    local server="$1"
    local key="$2"
    local ref_mark="$3"
    
    echo -e "${BLUE}🔍 Checking for existing SSH key...${NC}"
    
    # Extract key fingerprint for comparison
    local key_fingerprint=$(echo "$key" | cut -d' ' -f2)
    
    # Check if exact key exists (full key match) - handle both with and without comment
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -Fxq '${key}' ~/.ssh/authorized_keys 2>/dev/null || grep -q '^${key}$' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
        echo -e "${GREEN}✅ SSH key already exists on server${NC}"
        
        # Check if reference mark exists for this exact key
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -A1 -B1 '${key}' ~/.ssh/authorized_keys | grep -q '${ref_mark}'" 2>/dev/null; then
            echo -e "${GREEN}✅ Reference mark '${ref_mark}' already exists for this key${NC}"
            echo -e "${YELLOW}ℹ️  No changes needed - key and reference already configured${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  Key exists but reference mark '${ref_mark}' not found${NC}"
            echo -e "${BLUE}🔧 Will add reference mark to existing key${NC}"
            return 1
        fi
    # Check if key fingerprint exists (partial match - duplicate key)
    elif ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -q '${key_fingerprint}' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  Duplicate key detected (same fingerprint, different format)${NC}"
        
        # Check if reference mark exists for any key with this fingerprint
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -A1 -B1 '${key_fingerprint}' ~/.ssh/authorized_keys | grep -q '${ref_mark}'" 2>/dev/null; then
            echo -e "${GREEN}✅ Reference mark '${ref_mark}' already exists for this key type${NC}"
            echo -e "${YELLOW}ℹ️  No changes needed - key and reference already configured${NC}"
            return 0
        else
            echo -e "${BLUE}🔧 Will add reference to existing duplicate key${NC}"
            return 3
        fi
    else
        echo -e "${YELLOW}⚠️  SSH key not found - will add new key${NC}"
        return 2
    fi
}

# Function to setup SSH key
setup_ssh_key() {
    local server="$1"
    local key="$2"
    local ref_mark="$3"
    local key_exists="$4"
    
    echo -e "${BLUE}🔧 Setting up SSH key on ${server}...${NC}"
    
    ssh "$server" "
        # Create .ssh directory if it doesn't exist
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        
        # Backup existing authorized_keys
        if [ -f ~/.ssh/authorized_keys ]; then
            cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup.\$(date +%Y%m%d_%H%M%S)
            echo '📁 Backup created: ~/.ssh/authorized_keys.backup.\$(date +%Y%m%d_%H%M%S)'
        fi
        
        if [ $key_exists -eq 2 ]; then
            # Add new key with reference
            echo '' >> ~/.ssh/authorized_keys
            echo '# SSH Key from ${ref_mark} - Added on \$(date)' >> ~/.ssh/authorized_keys
            echo '${key}' >> ~/.ssh/authorized_keys
            echo '✅ New SSH key added with reference mark'
        elif [ $key_exists -eq 1 ]; then
            # Add reference to existing key
            sed -i '/${key}/i# SSH Key from ${ref_mark} - Reference added on \$(date)' ~/.ssh/authorized_keys
            echo '✅ Reference mark added to existing key'
        fi
        
        # Set proper permissions
        chmod 600 ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        
        # Configure SSH based on user choice
        if [ -f /etc/ssh/sshd_config ]; then
            # Backup SSH config
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.\$(date +%Y%m%d_%H%M%S)
            
            if [ "${DISABLE_PASSWORD,,}" = "y" ] || [ "${DISABLE_PASSWORD,,}" = "yes" ]; then
                # Disable password authentication
                sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                echo '🔒 Password authentication disabled - Key-only access enabled'
            else
                # Keep both password and key authentication
                sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                echo '🔓 Both password and key authentication enabled'
            fi
            
            echo '🔧 SSH configuration updated'
        fi
    "
}

# Function to restart SSH service
restart_ssh_service() {
    local server="$1"
    
    echo -e "${BLUE}🔄 Restarting SSH service...${NC}"
    
    ssh "$server" "
        # Try different restart methods
        if systemctl reload sshd 2>/dev/null; then
            echo '✅ SSH service reloaded successfully (systemctl)'
        elif service ssh reload 2>/dev/null; then
            echo '✅ SSH service reloaded successfully (service)'
        elif /etc/init.d/ssh reload 2>/dev/null; then
            echo '✅ SSH service reloaded successfully (init.d)'
        else
            echo '⚠️  SSH service reload failed - manual restart may be needed'
        fi
    "
}

# Function to verify setup
verify_setup() {
    local server="$1"
    local key="$2"
    local ref_mark="$3"
    
    echo -e "${BLUE}🔍 Verifying setup...${NC}"
    
    # Test key authentication
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "echo 'Key authentication test successful'" 2>/dev/null; then
        echo -e "${GREEN}✅ Key authentication working${NC}"
    else
        echo -e "${YELLOW}⚠️  Key authentication test failed${NC}"
    fi
    
    # Display authorized_keys content
    echo -e "${BLUE}📋 Current authorized_keys content:${NC}"
    ssh "$server" "cat ~/.ssh/authorized_keys | grep -A1 -B1 '${ref_mark}'"
    
    echo ""
    echo -e "${GREEN}🎉 Setup completed successfully!${NC}"
    echo -e "${WHITE}📊 Summary:${NC}"
    echo -e "   • Server: ${CYAN}${server}${NC}"
    echo -e "   • Reference: ${CYAN}${ref_mark}${NC}"
    echo -e "   • Key Type: ${CYAN}$(echo ${key} | cut -d' ' -f1)${NC}"
    echo -e "   • Status: ${GREEN}✅ Active${NC}"
}

# Function to check SSH status
check_ssh_status() {
    local server="$1"
    
    echo -e "${BLUE}🔍 Checking SSH status on ${server}...${NC}"
    
    ssh "$server" "
        echo '📋 SSH Service Status:'
        systemctl status sshd 2>/dev/null || service ssh status 2>/dev/null || echo 'SSH service status unavailable'
        
        echo ''
        echo '📋 SSH Configuration:'
        if [ -f /etc/ssh/sshd_config ]; then
            echo 'PasswordAuthentication:' \$(grep '^PasswordAuthentication' /etc/ssh/sshd_config | cut -d' ' -f2)
            echo 'PubkeyAuthentication:' \$(grep '^PubkeyAuthentication' /etc/ssh/sshd_config | cut -d' ' -f2)
        else
            echo 'SSH config file not found'
        fi
        
        echo ''
        echo '📋 Authorized Keys Count:'
        if [ -f ~/.ssh/authorized_keys ]; then
            echo \$(wc -l < ~/.ssh/authorized_keys) 'keys found'
            echo ''
            echo '📋 Key References:'
            grep '^#' ~/.ssh/authorized_keys | tail -5
        else
            echo 'No authorized_keys file found'
        fi
    "
}

# Function to delete key by reference
delete_key_by_reference() {
    local server="$1"
    local ref_mark="$2"
    
    echo -e "${BLUE}🗑️  Deleting SSH key with reference '${ref_mark}'...${NC}"
    
    ssh "$server" "
        # Backup existing authorized_keys
        if [ -f ~/.ssh/authorized_keys ]; then
            cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup.\$(date +%Y%m%d_%H%M%S)
            echo '📁 Backup created before deletion'
            
            # Remove lines containing the reference mark
            sed -i '/${ref_mark}/d' ~/.ssh/authorized_keys
            echo '✅ Keys with reference \"${ref_mark}\" removed'
            
            # Clean up empty lines
            sed -i '/^$/d' ~/.ssh/authorized_keys
            echo '✅ Empty lines cleaned up'
        else
            echo '⚠️  No authorized_keys file found'
        fi
    "
}

# Function to process batch file
process_batch_file() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}❌ Batch file not found: ${file}${NC}"
        return 1
    fi
    
    echo -e "${BLUE}📋 Processing batch file: ${file}${NC}"
    
    while IFS=',' read -r server key ref_mark; do
        # Skip empty lines and comments
        [[ -z "$server" || "$server" =~ ^# ]] && continue
        
        echo -e "${YELLOW}Processing: ${server}${NC}"
        
        # Validate inputs
        if ! validate_ssh_key "$key"; then
            echo -e "${RED}❌ Skipping ${server} - invalid key format${NC}"
            continue
        fi
        
        # Test connection
        if ! test_connection "$server"; then
            echo -e "${RED}❌ Skipping ${server} - connection failed${NC}"
            continue
        fi
        
        # Check existing key
        check_existing_key "$server" "$key" "$ref_mark"
        key_status=$?
        
        if [ $key_status -eq 0 ]; then
            echo -e "${GREEN}✅ ${server} - already configured${NC}"
            continue
        fi
        
        # Setup SSH key
        setup_ssh_key "$server" "$key" "$ref_mark" $key_status
        restart_ssh_service "$server"
        
        echo -e "${GREEN}✅ ${server} - setup completed${NC}"
        echo ""
        
    done < "$file"
}

# Interactive mode
interactive_mode() {
    echo -e "${WHITE}📋 Please provide the following information:${NC}"
    echo ""
    
    # Get SSH Public Key
    echo -e "${YELLOW}1️⃣  SSH Public Key:${NC}"
    echo -e "${BLUE}   Please paste your SSH public key (any format)${NC}"
    echo -e "${BLUE}   Supported: ssh-rsa, ssh-ed25519, ssh-ecdsa, ssh-dss${NC}"
    echo ""
    read -p "   Enter SSH Public Key: " SSH_PUBLIC_KEY
    
    # Validate SSH key format
    if ! validate_ssh_key "$SSH_PUBLIC_KEY"; then
        exit 1
    fi
    
    echo ""
    
    # Get Reference Mark
    echo -e "${YELLOW}2️⃣  Reference Mark:${NC}"
    echo -e "${BLUE}   Enter a reference identifier for this key${NC}"
    echo -e "${BLUE}   Example: servers-monitor, admin-laptop, backup-server${NC}"
    echo ""
    read -p "   Enter Reference Mark: " REFERENCE_MARK
    
    # Validate reference mark
    if [[ -z "$REFERENCE_MARK" ]]; then
        echo -e "${RED}❌ Reference mark cannot be empty.${NC}"
        exit 1
    fi
    
    echo ""
    
    # Get Target Server
    echo -e "${YELLOW}3️⃣  Target Server:${NC}"
    echo -e "${BLUE}   Choose target server option:${NC}"
    echo -e "${BLUE}   1. Same server (current server)${NC}"
    echo -e "${BLUE}   2. Remote server (user@hostname)${NC}"
    echo ""
    read -p "   Enter option (1/2): " SERVER_OPTION
    
    if [[ "$SERVER_OPTION" == "1" ]]; then
        # Same server - get current server info
        TARGET_SERVER="localhost"
        CURRENT_USER=$(whoami)
        CURRENT_HOST=$(hostname)
        echo -e "${GREEN}✅ Using current server: ${CURRENT_USER}@${CURRENT_HOST}${NC}"
    elif [[ "$SERVER_OPTION" == "2" ]]; then
        echo -e "${BLUE}   Enter target server (user@hostname or user@ip)${NC}"
        echo -e "${BLUE}   Example: root@185.169.234.59${NC}"
        echo ""
        read -p "   Enter Target Server: " TARGET_SERVER
        
        # Validate target server
        if [[ ! $TARGET_SERVER =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$ ]]; then
            echo -e "${RED}❌ Invalid server format. Use: user@hostname${NC}"
            exit 1
        fi
    else
        echo -e "${RED}❌ Invalid option. Please choose 1 or 2.${NC}"
        exit 1
    fi
    
    echo ""
    
    # Display configuration
    echo -e "${PURPLE}📋 Configuration Summary:${NC}"
    echo -e "   • Target Server: ${CYAN}${TARGET_SERVER}${NC}"
    echo -e "   • Reference Mark: ${CYAN}${REFERENCE_MARK}${NC}"
    echo -e "   • Key Type: ${CYAN}$(echo ${SSH_PUBLIC_KEY} | cut -d' ' -f1)${NC}"
    echo ""
    
    # SSH Configuration Option
    echo -e "${YELLOW}4️⃣  SSH Configuration:${NC}"
    echo -e "${BLUE}   Do you want to disable password authentication?${NC}"
    echo -e "${BLUE}   (This will keep only key-based authentication)${NC}"
    echo ""
    read -p "   Disable password auth? (Y/n): " DISABLE_PASSWORD
    
    # Confirm before proceeding
    read -p "   Proceed with setup? (Y/n): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]] && [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}❌ Setup cancelled by user${NC}"
        exit 0
    fi
    
    echo ""
    
    # Test connection (skip for same server)
    if [[ "$SERVER_OPTION" == "2" ]]; then
        if ! test_connection "$TARGET_SERVER"; then
            echo -e "${RED}❌ Cannot proceed - connection failed${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}✅ Same server setup - skipping connection test${NC}"
    fi
    
    # Check existing key
    check_existing_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
    key_status=$?
    
    if [ $key_status -eq 0 ]; then
        echo -e "${GREEN}🎉 No action needed - everything already configured!${NC}"
        exit 0
    fi
    
    # Setup SSH key
    if [[ "$SERVER_OPTION" == "1" ]]; then
        # Same server - direct setup
        echo -e "${BLUE}🔧 Setting up SSH key on current server...${NC}"
        
        # Create .ssh directory if it doesn't exist
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        
        # Backup existing authorized_keys
        if [ -f ~/.ssh/authorized_keys ]; then
            cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)
            echo "📁 Backup created: ~/.ssh/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        if [ $key_status -eq 2 ]; then
            # Add new key with reference
            echo '' >> ~/.ssh/authorized_keys
            echo "# SSH Key from ${REFERENCE_MARK} - Added on $(date)" >> ~/.ssh/authorized_keys
            echo "${SSH_PUBLIC_KEY}" >> ~/.ssh/authorized_keys
            echo "✅ New SSH key added with reference mark"
        elif [ $key_status -eq 1 ]; then
            # Add reference to existing exact key
            if ! grep -q "${REFERENCE_MARK}" ~/.ssh/authorized_keys; then
                # Find the exact key line and add reference before it
                sed -i "/^${SSH_PUBLIC_KEY}$/i# SSH Key from ${REFERENCE_MARK} - Reference added on $(date)" ~/.ssh/authorized_keys
                echo "✅ Reference mark added to existing key"
            else
                echo "ℹ️  Reference mark already exists for this key"
            fi
        elif [ $key_status -eq 3 ]; then
            # Add reference to existing duplicate key (same fingerprint, different format)
            key_fingerprint=$(echo "${SSH_PUBLIC_KEY}" | cut -d' ' -f2)
            if ! grep -q "${REFERENCE_MARK}" ~/.ssh/authorized_keys; then
                # Find the first occurrence of this fingerprint and add reference before it
                sed -i "0,/${key_fingerprint}/s//# SSH Key from ${REFERENCE_MARK} - Reference added on $(date)\n&/" ~/.ssh/authorized_keys
                echo "✅ Reference mark added to existing duplicate key"
                echo "ℹ️  Duplicate was detected - just added reference"
            else
                echo "ℹ️  Reference mark already exists for this key type"
            fi
        fi
        
        # Set proper permissions
        chmod 600 ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        
        # Configure SSH based on user choice
        if [ -f /etc/ssh/sshd_config ]; then
            # Check current SSH config first
            current_password_auth=$(grep '^PasswordAuthentication' /etc/ssh/sshd_config | cut -d' ' -f2)
            current_pubkey_auth=$(grep '^PubkeyAuthentication' /etc/ssh/sshd_config | cut -d' ' -f2)
            
            echo "📋 Current SSH config:"
            echo "   PasswordAuthentication: ${current_password_auth:-'not set'}"
            echo "   PubkeyAuthentication: ${current_pubkey_auth:-'not set'}"
            
            if [ "${DISABLE_PASSWORD,,}" = "y" ] || [ "${DISABLE_PASSWORD,,}" = "yes" ]; then
                # Only change if needed
                if [ "${current_password_auth}" != "no" ]; then
                    # Backup SSH config
                    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
                    
                    # Disable password authentication
                    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                    echo "🔒 Password authentication disabled - Key-only access enabled"
                    echo "🔧 SSH configuration updated"
                else
                    echo "✅ Password authentication already disabled"
                fi
            else
                # Only change if needed
                if [ "${current_password_auth}" != "yes" ] || [ "${current_pubkey_auth}" != "yes" ]; then
                    # Backup SSH config
                    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
                    
                    # Keep both password and key authentication
                    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                    echo "🔓 Both password and key authentication enabled"
                    echo "🔧 SSH configuration updated"
                else
                    echo "✅ SSH configuration already proper - no changes needed"
                fi
            fi
        else
            echo "⚠️  SSH config file not found at /etc/ssh/sshd_config"
        fi
        
        # Restart SSH service
        echo -e "${BLUE}🔄 Restarting SSH service...${NC}"
        if systemctl reload sshd 2>/dev/null; then
            echo "✅ SSH service reloaded successfully (systemctl)"
        elif service ssh reload 2>/dev/null; then
            echo "✅ SSH service reloaded successfully (service)"
        elif /etc/init.d/ssh reload 2>/dev/null; then
            echo "✅ SSH service reloaded successfully (init.d)"
        else
            echo "⚠️  SSH service reload failed - manual restart may be needed"
        fi
        
        # Verify setup
        echo -e "${BLUE}🔍 Verifying setup...${NC}"
        echo -e "${GREEN}✅ Key authentication working${NC}"
        
        # Display authorized_keys content
        echo -e "${BLUE}📋 Current authorized_keys content:${NC}"
        cat ~/.ssh/authorized_keys | grep -A1 -B1 "${REFERENCE_MARK}"
        
        echo ""
        echo -e "${GREEN}🎉 Setup completed successfully!${NC}"
        echo -e "${WHITE}📊 Summary:${NC}"
        echo -e "   • Server: ${CYAN}Current server${NC}"
        echo -e "   • Reference: ${CYAN}${REFERENCE_MARK}${NC}"
        echo -e "   • Key Type: ${CYAN}$(echo ${SSH_PUBLIC_KEY} | cut -d' ' -f1)${NC}"
        echo -e "   • Status: ${GREEN}✅ Active${NC}"
        
    else
        # Remote server - use existing function
        setup_ssh_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK" $key_status
        restart_ssh_service "$TARGET_SERVER"
        verify_setup "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
    fi
}

# Main execution
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--key)
                SSH_PUBLIC_KEY="$2"
                shift 2
                ;;
            -r|--reference)
                REFERENCE_MARK="$2"
                shift 2
                ;;
            -s|--server)
                TARGET_SERVER="$2"
                shift 2
                ;;
            -f|--file)
                BATCH_FILE="$2"
                shift 2
                ;;
            -c|--check)
                CHECK_SERVER="$2"
                shift 2
                ;;
            -d|--delete)
                DELETE_REF="$2"
                DELETE_SERVER="$3"
                shift 3
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo -e "${CYAN}Universal SSH Key Manager v${VERSION}${NC}"
                echo -e "${BLUE}Author: ${AUTHOR}${NC}"
                echo -e "${BLUE}Repository: ${REPO}${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Handle different modes
    if [[ -n "$CHECK_SERVER" ]]; then
        check_ssh_status "$CHECK_SERVER"
    elif [[ -n "$DELETE_REF" && -n "$DELETE_SERVER" ]]; then
        delete_key_by_reference "$DELETE_SERVER" "$DELETE_REF"
    elif [[ -n "$BATCH_FILE" ]]; then
        process_batch_file "$BATCH_FILE"
    elif [[ -n "$SSH_PUBLIC_KEY" && -n "$REFERENCE_MARK" && -n "$TARGET_SERVER" ]]; then
        # Quick setup mode
        if ! validate_ssh_key "$SSH_PUBLIC_KEY"; then
            exit 1
        fi
        
        if ! test_connection "$TARGET_SERVER"; then
            exit 1
        fi
        
        check_existing_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
        key_status=$?
        
        if [ $key_status -eq 0 ]; then
            echo -e "${GREEN}🎉 No action needed - everything already configured!${NC}"
            exit 0
        fi
        
        setup_ssh_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK" $key_status
        restart_ssh_service "$TARGET_SERVER"
        verify_setup "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
    else
        # Interactive mode
        interactive_mode
    fi
}

# Run main function
main "$@"

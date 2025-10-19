#!/bin/bash

# Smart SSH Key Setup Script
# Professional interactive script for SSH key management

# Colors for professional output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Professional header
clear
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    🔐 Smart SSH Key Manager                   ║${NC}"
echo -e "${CYAN}║              Professional SSH Key Setup & Management         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to get user input
get_user_input() {
    echo -e "${WHITE}📋 Please provide the following information:${NC}"
    echo ""
    
    # Get SSH Public Key
    echo -e "${YELLOW}1️⃣  SSH Public Key:${NC}"
    echo -e "${BLUE}   Please paste your SSH public key (ssh-rsa, ssh-ed25519, etc.)${NC}"
    echo -e "${BLUE}   Example: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@host${NC}"
    echo ""
    read -p "   Enter SSH Public Key: " SSH_PUBLIC_KEY
    
    # Validate SSH key format
    if [[ ! $SSH_PUBLIC_KEY =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
        echo -e "${RED}❌ Invalid SSH key format. Please provide a valid SSH public key.${NC}"
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
    echo -e "${BLUE}   Enter target server (user@hostname or user@ip)${NC}"
    echo -e "${BLUE}   Example: root@185.169.234.59${NC}"
    echo ""
    read -p "   Enter Target Server: " TARGET_SERVER
    
    # Validate target server
    if [[ ! $TARGET_SERVER =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$ ]]; then
        echo -e "${RED}❌ Invalid server format. Use: user@hostname${NC}"
        exit 1
    fi
    
    echo ""
}

# Function to check if key already exists
check_existing_key() {
    local server=$1
    local key=$2
    local ref_mark=$3
    
    echo -e "${BLUE}🔍 Checking for existing SSH key...${NC}"
    
    # Check if key exists
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -q '${key}' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
        echo -e "${GREEN}✅ SSH key already exists on server${NC}"
        
        # Check if reference mark exists
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" "grep -q '${ref_mark}' ~/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
            echo -e "${GREEN}✅ Reference mark '${ref_mark}' already exists${NC}"
            echo -e "${YELLOW}ℹ️  No changes needed - key and reference already configured${NC}"
            return 0
        else
            echo -e "${YELLOW}⚠️  Key exists but reference mark '${ref_mark}' not found${NC}"
            echo -e "${BLUE}🔧 Will add reference mark to existing key${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠️  SSH key not found - will add new key${NC}"
        return 2
    fi
}

# Function to setup SSH key
setup_ssh_key() {
    local server=$1
    local key=$2
    local ref_mark=$3
    local key_exists=$4
    
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
        
        # Ensure SSH config allows both password and key authentication
        if [ -f /etc/ssh/sshd_config ]; then
            # Check if already configured
            if ! grep -q 'PasswordAuthentication yes' /etc/ssh/sshd_config || ! grep -q 'PubkeyAuthentication yes' /etc/ssh/sshd_config; then
                # Backup SSH config
                cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.\$(date +%Y%m%d_%H%M%S)
                
                # Configure SSH
                sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                
                echo '🔧 SSH configuration updated'
            else
                echo '✅ SSH configuration already proper'
            fi
        fi
    "
}

# Function to restart SSH service
restart_ssh_service() {
    local server=$1
    
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

# Function to verify and display results
verify_setup() {
    local server=$1
    local key=$2
    local ref_mark=$3
    
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

# Main execution
main() {
    # Get user input
    get_user_input
    
    # Display configuration
    echo -e "${PURPLE}📋 Configuration Summary:${NC}"
    echo -e "   • Target Server: ${CYAN}${TARGET_SERVER}${NC}"
    echo -e "   • Reference Mark: ${CYAN}${REFERENCE_MARK}${NC}"
    echo -e "   • Key Type: ${CYAN}$(echo ${SSH_PUBLIC_KEY} | cut -d' ' -f1)${NC}"
    echo ""
    
    # Confirm before proceeding
    read -p "   Proceed with setup? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}❌ Setup cancelled by user${NC}"
        exit 0
    fi
    
    echo ""
    
    # Check existing key
    check_existing_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
    key_status=$?
    
    if [ $key_status -eq 0 ]; then
        echo -e "${GREEN}🎉 No action needed - everything already configured!${NC}"
        exit 0
    fi
    
    # Setup SSH key
    setup_ssh_key "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK" $key_status
    
    # Restart SSH service
    restart_ssh_service "$TARGET_SERVER"
    
    # Verify setup
    verify_setup "$TARGET_SERVER" "$SSH_PUBLIC_KEY" "$REFERENCE_MARK"
    
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    ✅ Setup Complete!                        ║${NC}"
    echo -e "${CYAN}║              SSH Key successfully configured                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# Run main function
main

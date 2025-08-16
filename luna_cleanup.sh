#!/bin/bash

# LUNA - Cleanup Script
# Completely removes LUNA and all its components from the system
# Supports Ubuntu and Raspberry Pi OS

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_DIR="$HOME/luna"
TRILIUM_DATA_DIR="$HOME/trilium-data"

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if user really wants to proceed
confirm_cleanup() {
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  WARNING ⚠️                           ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  This will PERMANENTLY DELETE:                            ║${NC}"
    echo -e "${RED}║  • All LUNA containers and images                         ║${NC}"
    echo -e "${RED}║  • All your notes and data in Trilium                     ║${NC}"
    echo -e "${RED}║  • All configuration files                                ║${NC}"
    echo -e "${RED}║  • All LUNA directories                                   ║${NC}"
    echo -e "${RED}║  • All shell aliases                                      ║${NC}"
    echo -e "${RED}║  • Systemd service (if installed)                         ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  THIS ACTION CANNOT BE UNDONE!                            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    read -p "Type 'DELETE LUNA' to confirm (or anything else to cancel): " confirmation
    
    if [ "$confirmation" != "DELETE LUNA" ]; then
        print_warning "Cleanup cancelled. LUNA remains installed."
        exit 0
    fi
    
    # Second confirmation for data
    echo
    print_warning "Do you want to backup your Trilium data before deletion?"
    read -p "Backup data? (y/N): " backup_confirm
    
    if [[ "$backup_confirm" =~ ^[Yy]$ ]]; then
        backup_data
    fi
}

# Backup data before deletion
backup_data() {
    print_status "Creating backup..."
    
    BACKUP_DIR="$HOME/luna_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Backup Trilium data if it exists
    if [ -d "$TRILIUM_DATA_DIR" ]; then
        print_status "Backing up Trilium data..."
        cp -r "$TRILIUM_DATA_DIR" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    # Backup configuration files
    if [ -d "$PROJECT_DIR" ]; then
        print_status "Backing up configuration files..."
        [ -f "$PROJECT_DIR/docker-compose.yml" ] && cp "$PROJECT_DIR/docker-compose.yml" "$BACKUP_DIR/" 2>/dev/null || true
        [ -f "$PROJECT_DIR/.env" ] && cp "$PROJECT_DIR/.env" "$BACKUP_DIR/" 2>/dev/null || true
        [ -d "$PROJECT_DIR/logs" ] && cp -r "$PROJECT_DIR/logs" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    print_success "Backup created at: $BACKUP_DIR"
    echo
}

# Stop and remove containers
cleanup_containers() {
    print_status "Stopping and removing LUNA containers..."
    
    if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
        cd "$PROJECT_DIR"
        docker-compose down -v 2>/dev/null || true
    fi
    
    # Remove containers if they still exist
    for container in trilium ollama luna-api; do
        if docker ps -a | grep -q "$container"; then
            print_status "Removing container: $container"
            docker rm -f "$container" 2>/dev/null || true
        fi
    done
    
    print_success "Containers removed"
}

# Remove Docker images
cleanup_images() {
    print_status "Removing LUNA Docker images..."
    
    # Remove images
    docker rmi zadam/trilium:latest 2>/dev/null || true
    docker rmi ollama/ollama:latest 2>/dev/null || true
    
    # Remove local build image
    if docker images | grep -q "luna-api"; then
        docker rmi $(docker images | grep luna-api | awk '{print $3}') 2>/dev/null || true
    fi
    
    # Clean up dangling images
    docker image prune -f 2>/dev/null || true
    
    print_success "Docker images removed"
}

# Remove Docker volumes
cleanup_volumes() {
    print_status "Removing Docker volumes..."
    
    # Remove named volumes
    docker volume rm luna_trilium-data 2>/dev/null || true
    docker volume rm luna_ollama-data 2>/dev/null || true
    
    # Clean up dangling volumes
    docker volume prune -f 2>/dev/null || true
    
    print_success "Docker volumes removed"
}

# Remove systemd service
cleanup_systemd() {
    if [ -f "/etc/systemd/system/luna.service" ]; then
        print_status "Removing systemd service..."
        
        sudo systemctl stop luna.service 2>/dev/null || true
        sudo systemctl disable luna.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/luna.service
        sudo systemctl daemon-reload
        
        print_success "Systemd service removed"
    fi
}

# Remove directories
cleanup_directories() {
    print_status "Removing LUNA directories..."
    
    # Remove project directory
    if [ -d "$PROJECT_DIR" ]; then
        rm -rf "$PROJECT_DIR"
        print_status "Removed $PROJECT_DIR"
    fi
    
    # Remove Trilium data directory
    if [ -d "$TRILIUM_DATA_DIR" ]; then
        rm -rf "$TRILIUM_DATA_DIR"
        print_status "Removed $TRILIUM_DATA_DIR"
    fi
    
    print_success "Directories removed"
}

# Remove shell aliases
cleanup_aliases() {
    print_status "Removing shell aliases..."
    
    # Remove from bashrc
    if grep -q "luna_aliases.sh" ~/.bashrc; then
        # Create backup of bashrc
        cp ~/.bashrc ~/.bashrc.luna_backup
        
        # Remove LUNA alias lines
        sed -i '/# LUNA aliases/d' ~/.bashrc
        sed -i '/luna_aliases.sh/d' ~/.bashrc
        
        print_status "Removed aliases from ~/.bashrc (backup: ~/.bashrc.luna_backup)"
    fi
    
    # Remove from zshrc if it exists
    if [ -f ~/.zshrc ] && grep -q "luna_aliases.sh" ~/.zshrc; then
        cp ~/.zshrc ~/.zshrc.luna_backup
        sed -i '/# LUNA aliases/d' ~/.zshrc
        sed -i '/luna_aliases.sh/d' ~/.zshrc
        print_status "Removed aliases from ~/.zshrc (backup: ~/.zshrc.luna_backup)"
    fi
    
    print_success "Shell aliases removed"
}

# Clean Docker system (optional)
cleanup_docker_system() {
    print_warning "Do you want to clean up unused Docker data?"
    print_warning "This will remove ALL unused containers, networks, images, and volumes (not just LUNA)"
    read -p "Clean Docker system? (y/N): " docker_clean
    
    if [[ "$docker_clean" =~ ^[Yy]$ ]]; then
        print_status "Cleaning Docker system..."
        docker system prune -a -f --volumes
        print_success "Docker system cleaned"
    fi
}

# Check what's installed
check_installation() {
    print_status "Checking LUNA installation..."
    
    local found=false
    
    # Check containers
    if docker ps -a 2>/dev/null | grep -q -E "(trilium|ollama|luna-api)"; then
        print_status "Found LUNA containers"
        found=true
    fi
    
    # Check directories
    if [ -d "$PROJECT_DIR" ] || [ -d "$TRILIUM_DATA_DIR" ]; then
        print_status "Found LUNA directories"
        found=true
    fi
    
    # Check systemd
    if [ -f "/etc/systemd/system/luna.service" ]; then
        print_status "Found systemd service"
        found=true
    fi
    
    # Check aliases
    if grep -q "luna_aliases.sh" ~/.bashrc 2>/dev/null; then
        print_status "Found shell aliases"
        found=true
    fi
    
    if [ "$found" = false ]; then
        print_warning "No LUNA installation found on this system"
        exit 0
    fi
}

# Generate cleanup report
generate_report() {
    print_status "Generating cleanup report..."
    
    REPORT_FILE="$HOME/luna_cleanup_report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "LUNA Cleanup Report"
        echo "==================="
        echo "Date: $(date)"
        echo "User: $USER"
        echo "System: $(uname -a)"
        echo ""
        echo "Removed Components:"
        echo "-------------------"
        
        # Check what was removed
        if ! docker ps -a 2>/dev/null | grep -q -E "(trilium|ollama|luna-api)"; then
            echo "✓ Docker containers"
        fi
        
        if [ ! -d "$PROJECT_DIR" ]; then
            echo "✓ Project directory: $PROJECT_DIR"
        fi
        
        if [ ! -d "$TRILIUM_DATA_DIR" ]; then
            echo "✓ Data directory: $TRILIUM_DATA_DIR"
        fi
        
        if [ ! -f "/etc/systemd/system/luna.service" ]; then
            echo "✓ Systemd service"
        fi
        
        if ! grep -q "luna_aliases.sh" ~/.bashrc 2>/dev/null; then
            echo "✓ Shell aliases"
        fi
        
        echo ""
        echo "Backup Location (if created): ${BACKUP_DIR:-None}"
        echo ""
        echo "Cleanup completed successfully!"
        
    } > "$REPORT_FILE"
    
    print_success "Cleanup report saved to: $REPORT_FILE"
}

# Main cleanup function
main() {
    print_status "Starting LUNA cleanup process..."
    echo
    
    # Check if LUNA is installed
    check_installation
    
    # Confirm with user
    confirm_cleanup
    
    # Perform cleanup
    cleanup_containers
    cleanup_images
    cleanup_volumes
    cleanup_systemd
    cleanup_directories
    cleanup_aliases
    
    # Optional Docker system cleanup
    cleanup_docker_system
    
    # Generate report
    generate_report
    
    echo
    print_success "🌙 LUNA has been completely removed from your system"
    
    if [ -n "$BACKUP_DIR" ]; then
        echo
        print_status "Your backup is located at: $BACKUP_DIR"
        print_status "You can restore from this backup if needed"
    fi
    
    echo
    print_status "Thank you for using LUNA!"
}

# Handle script arguments
case "${1:-}" in
    --force)
        print_warning "Force mode: Skipping confirmation"
        backup_data
        cleanup_containers
        cleanup_images
        cleanup_volumes
        cleanup_systemd
        cleanup_directories
        cleanup_aliases
        generate_report
        ;;
    --check)
        check_installation
        ;;
    --help)
        echo "LUNA Cleanup Script"
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --force   Skip confirmation prompts (still creates backup)"
        echo "  --check   Check what LUNA components are installed"
        echo "  --help    Show this help message"
        echo ""
        echo "Without options, runs interactive cleanup with confirmations"
        ;;
    *)
        main
        ;;
esac
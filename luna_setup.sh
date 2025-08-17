#!/bin/bash

# LUNA - Local Understanding & Note Assistant
# Complete self-hosted AI-powered knowledge management system
# No third-party accounts required
# Supports Ubuntu and Raspberry Pi

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - Using unique high ports to avoid conflicts
TRILIUM_PORT=9876  # Trilium Notes web UI
OLLAMA_PORT=9877   # Ollama API
API_PORT=9878      # Luna API
TRILIUM_DATA_DIR="$HOME/trilium-data"
PROJECT_DIR="$HOME/luna"
# WHISPER_MODEL and OLLAMA_MODEL are set in check_system()

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

# Detect system type and architecture
check_system() {
    print_status "Checking system compatibility..."
    
    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
    else
        OS_NAME="Unknown"
        OS_VERSION="Unknown"
    fi
    
    # Detect architecture
    ARCH=$(uname -m)
    
    # Detect if running on Raspberry Pi
    IS_RASPBERRY_PI=false
    if [ -f /proc/device-tree/model ]; then
        MODEL=$(cat /proc/device-tree/model | tr -d '\0')
        if [[ "$MODEL" == *"Raspberry Pi"* ]]; then
            IS_RASPBERRY_PI=true
            print_success "Raspberry Pi detected: $MODEL"
        fi
    fi
    
    # System detection summary
    if [ "$IS_RASPBERRY_PI" = true ]; then
        print_success "Running on Raspberry Pi ($ARCH)"
    elif [[ "$OS_NAME" == *"Ubuntu"* ]]; then
        print_success "Running on Ubuntu $OS_VERSION ($ARCH)"
    elif [[ "$OS_NAME" == *"Debian"* ]]; then
        print_success "Running on Debian-based system ($ARCH)"
    else
        print_warning "Running on $OS_NAME ($ARCH) - compatibility not guaranteed"
    fi
    
    # Architecture-specific checks
    if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "armv7l" ]]; then
        print_status "ARM architecture detected - optimizing for ARM"
        # Will use ARM-optimized images where available
        OLLAMA_IMAGE="ollama/ollama:latest"
        WHISPER_MODEL="tiny"  # Smaller model for ARM
    elif [[ "$ARCH" == "x86_64" ]]; then
        print_status "x86_64 architecture detected"
        OLLAMA_IMAGE="ollama/ollama:latest"
        WHISPER_MODEL="base"
    else
        print_warning "Unknown architecture: $ARCH - using defaults"
        OLLAMA_IMAGE="ollama/ollama:latest"
        WHISPER_MODEL="tiny"
    fi
    
    # Check available memory
    MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEMORY_GB=$((MEMORY_KB / 1024 / 1024))
    
    if [ $MEMORY_GB -lt 2 ]; then
        print_error "Less than 2GB RAM detected. LUNA requires at least 2GB RAM."
        print_warning "Consider adding swap space or upgrading your system."
        read -p "Continue anyway? (y/N): " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    elif [ $MEMORY_GB -lt 4 ]; then
        print_warning "${MEMORY_GB}GB RAM detected. Using lightweight models."
        OLLAMA_MODEL="gemma3:1b"  # Smaller model for low RAM
        WHISPER_MODEL="tiny"
    else
        print_success "${MEMORY_GB}GB RAM detected - sufficient for standard models"
        OLLAMA_MODEL="gemma3:1b"
    fi
    
    # Export for use in other functions
    export IS_RASPBERRY_PI
    export ARCH
    export OS_NAME
    export OLLAMA_IMAGE
    export OLLAMA_MODEL
    export WHISPER_MODEL
}

# Install Docker if not present
install_docker() {
    if ! command -v docker &> /dev/null; then
        print_status "Installing Docker..."
        
        # Use appropriate installation method based on system
        if [ "$IS_RASPBERRY_PI" = true ] || [[ "$OS_NAME" == *"Raspbian"* ]]; then
            # Raspberry Pi specific installation
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
        elif [[ "$OS_NAME" == *"Ubuntu"* ]] || [[ "$OS_NAME" == *"Debian"* ]]; then
            # Ubuntu/Debian installation
            sudo apt update
            sudo apt install -y ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        else
            # Generic installation
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh
        fi
        
        # Add user to docker group
        sudo usermod -aG docker $USER
        
        # Start and enable Docker
        sudo systemctl start docker
        sudo systemctl enable docker
        
        print_success "Docker installed successfully"
        print_warning "Please log out and back in for Docker permissions to take effect"
    else
        print_success "Docker already installed ($(docker --version))"
    fi
}

# Install Docker Compose if not present
install_docker_compose() {
    # Check for docker compose (v2) first
    if docker compose version &> /dev/null; then
        print_success "Docker Compose v2 already installed ($(docker compose version))"
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        print_success "Docker Compose v1 already installed ($(docker-compose --version))"
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        print_status "Installing Docker Compose..."
        
        if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "armv7l" ]]; then
            # ARM installation (including Raspberry Pi)
            sudo apt update
            sudo apt install -y docker-compose
        elif [[ "$ARCH" == "x86_64" ]]; then
            # x86_64 installation - try to get latest version
            COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
            sudo curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        else
            # Fallback to apt
            sudo apt update
            sudo apt install -y docker-compose
        fi
        
        # Verify installation
        if docker compose version &> /dev/null; then
            print_success "Docker Compose v2 installed successfully"
            DOCKER_COMPOSE_CMD="docker compose"
        elif command -v docker-compose &> /dev/null; then
            print_success "Docker Compose v1 installed successfully"
            DOCKER_COMPOSE_CMD="docker-compose"
        else
            print_error "Failed to install Docker Compose"
            exit 1
        fi
    fi
    
    # Export for use in other functions
    export DOCKER_COMPOSE_CMD
}

# Create project directory structure
create_directories() {
    print_status "Creating project directories..."
    
    mkdir -p "$PROJECT_DIR"/{api,scripts,config,logs}
    mkdir -p "$TRILIUM_DATA_DIR"
    
    print_success "Project directories created at $PROJECT_DIR"
}

# Create Docker Compose configuration
create_docker_compose() {
    print_status "Creating Docker Compose configuration..."
    
    cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  trilium:
    image: zadam/trilium:latest
    container_name: trilium
    ports:
      - "9876:8080"  # Unique port for Trilium UI
    volumes:
      - trilium-data:/home/node/trilium-data
    environment:
      - TRILIUM_DATA_DIR=/home/node/trilium-data
    restart: unless-stopped
    networks:
      - luna-net

  ollama:
    image: ${OLLAMA_IMAGE:-ollama/ollama:latest}
    container_name: ollama
    ports:
      - "9877:11434"  # Unique port for Ollama API
    volumes:
      - ollama-data:/root/.ollama
    restart: unless-stopped
    environment:
      - OLLAMA_ORIGINS=*
    networks:
      - luna-net
    # For GPU support on Pi 5, uncomment the following:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: 1
    #           capabilities: [gpu]

  luna-api:
    build: ./api
    container_name: luna-api
    ports:
      - "9878:5000"  # Unique port for Luna API
    volumes:
      - ./api:/app
      - ./logs:/app/logs
      - /tmp:/tmp
    environment:
      - TRILIUM_URL=http://trilium:8080
      - OLLAMA_URL=http://ollama:11434
      - WHISPER_MODEL=${WHISPER_MODEL:-tiny}
      - OLLAMA_MODEL=${OLLAMA_MODEL:-gemma3:1b}
      - OLLAMA_ORIGINS=*
    depends_on:
      - trilium
      - ollama
    restart: unless-stopped
    networks:
      - luna-net

volumes:
  trilium-data:
  ollama-data:

networks:
  luna-net:
    driver: bridge
EOF

    print_success "Docker Compose configuration created"
}

# Create the API service
create_api_service() {
    print_status "Creating Knowledge Base API service..."
    
    # Create Dockerfile for API
    cat > "$PROJECT_DIR/api/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    libopenblas-dev \
    liblapack-dev \
    libasound2-dev \
    portaudio19-dev \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies with architecture-specific optimizations
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt || \
    (pip install --no-cache-dir --no-deps -r requirements.txt && \
     pip install --no-cache-dir whisper)

# Copy application code
COPY . .

EXPOSE 5000

CMD ["python", "app.py"]
EOF

    # Create requirements.txt
    cat > "$PROJECT_DIR/api/requirements.txt" << 'EOF'
flask==2.3.2
flask-cors==4.0.0
requests==2.31.0
openai-whisper==20231117
torch==2.0.1
torchaudio==2.0.2
numpy==1.24.3
python-multipart==0.0.6
pydub==0.25.1
soundfile==0.12.1
webrtcvad==2.0.10
pyaudio==0.2.11
EOF

    # Create main API application
    cat > "$PROJECT_DIR/api/app.py" << 'EOF'
from flask import Flask, request, jsonify
from flask_cors import CORS
import requests
import whisper
import tempfile
import os
import logging
from datetime import datetime
import json

app = Flask(__name__)
# Enable CORS for all routes and origins
CORS(app, resources={r"/*": {"origins": "*"}})

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/app/logs/api.log'),
        logging.StreamHandler()
    ]
)

# Configuration
TRILIUM_URL = os.getenv('TRILIUM_URL', 'http://localhost:8080')
OLLAMA_URL = os.getenv('OLLAMA_URL', 'http://localhost:11434')

# Load Whisper model
WHISPER_MODEL_SIZE = os.getenv('WHISPER_MODEL', 'tiny')
try:
    whisper_model = whisper.load_model(WHISPER_MODEL_SIZE)
    logging.info(f"Whisper model ({WHISPER_MODEL_SIZE}) loaded successfully")
except Exception as e:
    logging.error(f"Failed to load Whisper model: {e}")
    whisper_model = None

class TriliumAPI:
    def __init__(self, base_url):
        self.base_url = base_url
        self.session = requests.Session()
    
    def create_note(self, title, content, parent_note_id=None, note_type='text'):
        """Create a new note in Trilium"""
        url = f"{self.base_url}/api/notes"
        data = {
            'title': title,
            'content': content,
            'type': note_type,
            'parentNoteId': parent_note_id or 'root'
        }
        
        try:
            response = self.session.post(url, json=data)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            logging.error(f"Failed to create note: {e}")
            return None
    
    def search_notes(self, query):
        """Search notes in Trilium"""
        url = f"{self.base_url}/api/notes/search"
        params = {'query': query}
        
        try:
            response = self.session.get(url, params=params)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            logging.error(f"Failed to search notes: {e}")
            return []

class OllamaAPI:
    def __init__(self, base_url):
        self.base_url = base_url
    
    def enhance_text(self, text, task="improve"):
        """Enhance text using local LLM"""
        url = f"{self.base_url}/api/generate"
        
        prompts = {
            "improve": f"Please improve and expand the following notes while maintaining the original meaning:\n\n{text}",
            "summarize": f"Please provide a concise summary of the following:\n\n{text}",
            "rephrase": f"Please rephrase the following text to be clearer and more professional:\n\n{text}",
            "expand": f"Please expand on the following notes with more detail and context:\n\n{text}"
        }
        
        model = os.getenv('OLLAMA_MODEL', 'llama3.2:1b')
        data = {
            "model": model,
            "prompt": prompts.get(task, prompts["improve"]),
            "stream": False
        }
        
        try:
            response = requests.post(url, json=data, timeout=30)
            response.raise_for_status()
            return response.json().get('response', text)
        except Exception as e:
            logging.error(f"Failed to enhance text: {e}")
            return text

# Initialize APIs
trilium_api = TriliumAPI(TRILIUM_URL)
ollama_api = OllamaAPI(OLLAMA_URL)

@app.route('/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'healthy', 'timestamp': datetime.now().isoformat()})

@app.route('/voice-to-text', methods=['POST'])
def voice_to_text():
    """Convert voice recording to text"""
    if not whisper_model:
        return jsonify({'error': 'Whisper model not available'}), 500
    
    if 'audio' not in request.files:
        return jsonify({'error': 'No audio file provided'}), 400
    
    audio_file = request.files['audio']
    
    try:
        # Save temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as tmp_file:
            audio_file.save(tmp_file.name)
            
            # Transcribe audio
            result = whisper_model.transcribe(tmp_file.name)
            text = result['text'].strip()
            
            # Clean up
            os.unlink(tmp_file.name)
            
            logging.info(f"Successfully transcribed audio: {text[:100]}...")
            return jsonify({'text': text})
            
    except Exception as e:
        logging.error(f"Voice transcription failed: {e}")
        return jsonify({'error': 'Failed to transcribe audio'}), 500

@app.route('/enhance-text', methods=['POST'])
def enhance_text():
    """Enhance text using LLM"""
    data = request.get_json()
    
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    
    text = data['text']
    task = data.get('task', 'improve')
    
    try:
        enhanced_text = ollama_api.enhance_text(text, task)
        return jsonify({'enhanced_text': enhanced_text})
    except Exception as e:
        logging.error(f"Text enhancement failed: {e}")
        return jsonify({'error': 'Failed to enhance text'}), 500

@app.route('/create-note', methods=['POST'])
def create_note():
    """Create a new note with optional AI enhancement"""
    data = request.get_json()
    
    if not data or 'title' not in data or 'content' not in data:
        return jsonify({'error': 'Title and content are required'}), 400
    
    title = data['title']
    content = data['content']
    enhance = data.get('enhance', False)
    parent_id = data.get('parent_note_id')
    
    try:
        # Enhance content if requested
        if enhance:
            content = ollama_api.enhance_text(content)
        
        # Create note in Trilium
        result = trilium_api.create_note(title, content, parent_id)
        
        if result:
            logging.info(f"Created note: {title}")
            return jsonify({'success': True, 'note': result})
        else:
            return jsonify({'error': 'Failed to create note'}), 500
            
    except Exception as e:
        logging.error(f"Note creation failed: {e}")
        return jsonify({'error': 'Failed to create note'}), 500

@app.route('/quick-note', methods=['POST'])
def quick_note():
    """Create a quick note from voice or text"""
    content_type = request.content_type
    
    if 'multipart/form-data' in content_type:
        # Voice note
        if 'audio' not in request.files:
            return jsonify({'error': 'No audio file provided'}), 400
            
        audio_file = request.files['audio']
        enhance = request.form.get('enhance', 'false').lower() == 'true'
        
        try:
            # Transcribe audio
            with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as tmp_file:
                audio_file.save(tmp_file.name)
                result = whisper_model.transcribe(tmp_file.name)
                text = result['text'].strip()
                os.unlink(tmp_file.name)
            
            # Generate title from content
            title_prompt = f"Generate a short, descriptive title (max 10 words) for this note:\n\n{text}"
            title = ollama_api.enhance_text(title_prompt, "summarize")[:100]
            
            # Enhance content if requested
            content = ollama_api.enhance_text(text) if enhance else text
            
            # Create note
            note_result = trilium_api.create_note(title, content)
            
            return jsonify({
                'success': True,
                'transcribed_text': text,
                'enhanced_content': content,
                'note': note_result
            })
            
        except Exception as e:
            logging.error(f"Quick voice note failed: {e}")
            return jsonify({'error': 'Failed to process voice note'}), 500
    
    else:
        # Text note
        data = request.get_json()
        if not data or 'content' not in data:
            return jsonify({'error': 'Content is required'}), 400
        
        content = data['content']
        enhance = data.get('enhance', False)
        
        try:
            # Generate title
            title_prompt = f"Generate a short, descriptive title (max 10 words) for this note:\n\n{content}"
            title = ollama_api.enhance_text(title_prompt, "summarize")[:100]
            
            # Enhance content if requested
            if enhance:
                content = ollama_api.enhance_text(content)
            
            # Create note
            note_result = trilium_api.create_note(title, content)
            
            return jsonify({
                'success': True,
                'title': title,
                'content': content,
                'note': note_result
            })
            
        except Exception as e:
            logging.error(f"Quick text note failed: {e}")
            return jsonify({'error': 'Failed to create quick note'}), 500

@app.route('/search', methods=['GET'])
def search_notes():
    """Search notes"""
    query = request.args.get('q', '')
    
    if not query:
        return jsonify({'error': 'Query parameter required'}), 400
    
    try:
        results = trilium_api.search_notes(query)
        return jsonify({'results': results})
    except Exception as e:
        logging.error(f"Search failed: {e}")
        return jsonify({'error': 'Search failed'}), 500

@app.route('/trilium-ai', methods=['POST'])
def trilium_ai_enhance():
    """AI enhancement endpoint specifically for Trilium integration"""
    data = request.get_json()
    
    if not data or 'text' not in data:
        return jsonify({'error': 'No text provided'}), 400
    
    text = data['text']
    task = data.get('task', 'improve')
    note_id = data.get('note_id', '')
    
    try:
        enhanced_text = ollama_api.enhance_text(text, task)
        
        # Log the enhancement for tracking
        logging.info(f"AI enhanced note {note_id} with task: {task}")
        
        return jsonify({
            'enhanced_text': enhanced_text,
            'original_text': text,
            'task': task,
            'note_id': note_id
        })
    except Exception as e:
        logging.error(f"Trilium AI enhancement failed: {e}")
        return jsonify({'error': 'Failed to enhance text'}), 500

@app.route('/ollama-chat', methods=['POST'])
def ollama_chat():
    """Direct chat interface with Ollama for Trilium"""
    data = request.get_json()
    
    if not data or 'prompt' not in data:
        return jsonify({'error': 'No prompt provided'}), 400
    
    prompt = data['prompt']
    context = data.get('context', '')
    
    # Build full prompt with context if provided
    if context:
        full_prompt = f"Context: {context}\\n\\nQuestion: {prompt}"
    else:
        full_prompt = prompt
    
    try:
        url = f"{OLLAMA_URL}/api/generate"
        model = os.getenv('OLLAMA_MODEL', 'llama3.2:1b')
        
        payload = {
            "model": model,
            "prompt": full_prompt,
            "stream": False
        }
        
        response = requests.post(url, json=payload, timeout=60)
        response.raise_for_status()
        
        result = response.json()
        ai_response = result.get('response', 'No response generated')
        
        logging.info(f"Ollama chat response generated for prompt: {prompt[:100]}...")
        
        return jsonify({
            'response': ai_response,
            'prompt': prompt,
            'context': context,
            'model': model
        })
        
    except Exception as e:
        logging.error(f"Ollama chat failed: {e}")
        return jsonify({'error': 'Failed to get AI response'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

    print_success "API service created"
}

# Create helper scripts
create_scripts() {
    print_status "Creating helper scripts..."
    
    # Voice note script
    cat > "$PROJECT_DIR/scripts/voice_note.py" << 'EOF'
#!/usr/bin/env python3
"""
Quick voice note capture script
Usage: python voice_note.py [--enhance] [--duration SECONDS]
"""

import argparse
import requests
import pyaudio
import wave
import tempfile
import os
import time

def record_audio(duration=10, sample_rate=44100, channels=1):
    """Record audio from microphone"""
    chunk = 1024
    format = pyaudio.paInt16
    
    audio = pyaudio.PyAudio()
    
    print(f"Recording for {duration} seconds... Press Ctrl+C to stop early")
    
    stream = audio.open(
        format=format,
        channels=channels,
        rate=sample_rate,
        input=True,
        frames_per_buffer=chunk
    )
    
    frames = []
    start_time = time.time()
    
    try:
        while time.time() - start_time < duration:
            data = stream.read(chunk)
            frames.append(data)
    except KeyboardInterrupt:
        print("\nRecording stopped by user")
    
    stream.stop_stream()
    stream.close()
    audio.terminate()
    
    # Save to temporary file
    with tempfile.NamedTemporaryFile(delete=False, suffix='.wav') as tmp_file:
        wave_file = wave.open(tmp_file.name, 'wb')
        wave_file.setnchannels(channels)
        wave_file.setsampwidth(audio.get_sample_size(format))
        wave_file.setframerate(sample_rate)
        wave_file.writeframes(b''.join(frames))
        wave_file.close()
        return tmp_file.name

def main():
    parser = argparse.ArgumentParser(description='Record and save voice note')
    parser.add_argument('--enhance', action='store_true', help='Enhance note with AI')
    parser.add_argument('--duration', type=int, default=30, help='Recording duration in seconds')
    parser.add_argument('--api-url', default='http://localhost:9878', help='API base URL')
    
    args = parser.parse_args()
    
    try:
        # Record audio
        audio_file = record_audio(args.duration)
        
        # Upload to API
        with open(audio_file, 'rb') as f:
            files = {'audio': f}
            data = {'enhance': str(args.enhance).lower()}
            
            response = requests.post(
                f"{args.api_url}/quick-note",
                files=files,
                data=data
            )
        
        # Clean up
        os.unlink(audio_file)
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ Note created successfully!")
            print(f"Title: {result.get('note', {}).get('title', 'Unknown')}")
            print(f"Transcribed: {result.get('transcribed_text', '')[:100]}...")
        else:
            print(f"❌ Failed to create note: {response.text}")
            
    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == '__main__':
    main()
EOF

    # Quick text note script
    cat > "$PROJECT_DIR/scripts/quick_note.py" << 'EOF'
#!/usr/bin/env python3
"""
Quick text note creation script
Usage: python quick_note.py "Your note content here" [--enhance]
"""

import argparse
import requests
import sys

def main():
    parser = argparse.ArgumentParser(description='Create a quick text note')
    parser.add_argument('content', help='Note content')
    parser.add_argument('--enhance', action='store_true', help='Enhance note with AI')
    parser.add_argument('--api-url', default='http://localhost:9878', help='API base URL')
    
    args = parser.parse_args()
    
    try:
        data = {
            'content': args.content,
            'enhance': args.enhance
        }
        
        response = requests.post(f"{args.api_url}/quick-note", json=data)
        
        if response.status_code == 200:
            result = response.json()
            print(f"✅ Note created successfully!")
            print(f"Title: {result.get('title', 'Unknown')}")
            if args.enhance:
                print(f"Enhanced content: {result.get('content', '')[:200]}...")
        else:
            print(f"❌ Failed to create note: {response.text}")
            
    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == '__main__':
    main()
EOF

    # Make scripts executable
    chmod +x "$PROJECT_DIR/scripts/"*.py
    
    print_success "Helper scripts created"
}

# Create Trilium integration info (removed widget - API endpoints still available)
create_trilium_integration() {
    print_status "Creating Trilium integration documentation..."
    
    mkdir -p "$PROJECT_DIR/trilium-integration"
    
    # Create API documentation
    cat > "$PROJECT_DIR/trilium-integration/API_DOCS.md" << 'EOF'
# Luna API Documentation

## Available API Endpoints

Luna provides several API endpoints that can be used to integrate AI capabilities with Trilium or other applications.

### Base URL
```
http://localhost:9878
```

### Endpoints

#### 1. Health Check
```
GET /health
```
Returns the API health status.

#### 2. Enhance Text
```
POST /enhance-text
```
**Body:**
```json
{
  "text": "Your text to enhance",
  "task": "improve" // Options: improve, summarize, expand, rephrase
}
```

#### 3. Trilium AI Enhancement
```
POST /trilium-ai
```
**Body:**
```json
{
  "text": "Note content",
  "task": "improve",
  "note_id": "optional_note_id"
}
```

#### 4. Chat with Ollama
```
POST /ollama-chat
```
**Body:**
```json
{
  "prompt": "Your question",
  "context": "Optional context from note"
}
```

#### 5. Create Note
```
POST /create-note
```
**Body:**
```json
{
  "title": "Note title",
  "content": "Note content",
  "enhance": false,
  "parent_note_id": "optional"
}
```

#### 6. Quick Note (Voice or Text)
```
POST /quick-note
```
**For text:** Send JSON with content
**For voice:** Send multipart form with audio file

#### 7. Search Notes
```
GET /search?q=your_search_query
```

## Using with curl

### Example: Enhance text
```bash
curl -X POST http://localhost:9878/enhance-text \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "task": "expand"}'
```

### Example: Chat with Ollama
```bash
curl -X POST http://localhost:9878/ollama-chat \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is machine learning?"}'
```

## Integration Ideas

1. **Browser Extensions**: Create a browser extension that sends selected text to Luna for enhancement
2. **Command Line Tools**: Use curl or httpie to interact with Luna from terminal
3. **Custom Scripts**: Write Python/JavaScript scripts to automate note creation and enhancement
4. **Webhooks**: Set up automation tools to send data to Luna for processing

## Notes

- All endpoints support CORS for browser-based access
- The API runs on port 9878 by default
- Ollama and Trilium services must be running for full functionality
EOF

    # Create a simple backup/restore script for Trilium notes
    cat > "$PROJECT_DIR/trilium-integration/backup_notes.py" << 'EOF'
#!/usr/bin/env python3
"""
Simple Trilium notes backup script
Usage: python backup_notes.py
"""

import requests
import json
import os
from datetime import datetime

TRILIUM_URL = "http://localhost:9876"
BACKUP_DIR = os.path.expanduser("~/luna/backups")

def backup_notes():
    """Create a backup of all Trilium notes"""
    
    os.makedirs(BACKUP_DIR, exist_ok=True)
    
    try:
        # This is a simplified backup - in reality, you'd use Trilium's export API
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        backup_file = os.path.join(BACKUP_DIR, f"trilium_backup_{timestamp}.json")
        
        print(f"Creating backup at: {backup_file}")
        print("Note: This requires manual export from Trilium web interface")
        print(f"1. Go to {TRILIUM_URL}")
        print("2. Use 'Import/Export' -> 'Export' to create a backup")
        print(f"3. Save the backup to: {backup_file}")
        
        return backup_file
        
    except Exception as e:
        print(f"Backup failed: {e}")
        return None

if __name__ == "__main__":
    backup_notes()
EOF

    chmod +x "$PROJECT_DIR/trilium-integration/backup_notes.py"
    
    print_success "API documentation created at $PROJECT_DIR/trilium-integration/"
}

# Create shell aliases for easy access
create_aliases() {
    print_status "Creating shell aliases for easy access..."
    
    # Create aliases file
    cat > "$PROJECT_DIR/luna_aliases.sh" << 'EOF'
#!/bin/bash
# LUNA aliases for easy access to services

# Access Trilium web interface
alias luna-trilium='echo "Open http://$(hostname -I | awk "{print \$1}"):9876 in your browser"'

# Shell access to containers
alias luna-api-shell='docker exec -it luna-api bash'
alias luna-ollama-shell='docker exec -it ollama bash'
alias luna-trilium-shell='docker exec -it trilium bash'

# Quick notes
alias luna-voice='python ~/luna/scripts/voice_note.py'
alias luna-note='python ~/luna/scripts/quick_note.py'

# API test
alias luna-test='curl -s http://localhost:9878/health | python3 -m json.tool'

# Logs
alias luna-logs='docker-compose -f ~/luna/docker-compose.yml logs -f'
alias luna-logs-api='docker-compose -f ~/luna/docker-compose.yml logs -f luna-api'
alias luna-logs-trilium='docker-compose -f ~/luna/docker-compose.yml logs -f trilium'

# Service management
alias luna-start='cd ~/luna && docker-compose up -d'
alias luna-stop='cd ~/luna && docker-compose down'
alias luna-restart='cd ~/luna && docker-compose restart'
alias luna-status='docker-compose -f ~/luna/docker-compose.yml ps'

# Trilium API access examples
alias luna-create-note='python3 -c "
import requests
import json
title = input(\"Note title: \")
content = input(\"Note content: \")
response = requests.post(\"http://localhost:9878/create-note\", json={\"title\": title, \"content\": content})
print(json.dumps(response.json(), indent=2))
"'

# Search notes
alias luna-search='python3 -c "
import requests
import json
query = input(\"Search query: \")
response = requests.get(f\"http://localhost:9878/search?q={query}\")
print(json.dumps(response.json(), indent=2))
"'

echo "LUNA aliases loaded! Type 'luna-' and press Tab to see available commands."
EOF
    
    # Add to bashrc if not already present
    if ! grep -q "luna_aliases.sh" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# LUNA aliases" >> ~/.bashrc
        echo "[ -f ~/luna/luna_aliases.sh ] && source ~/luna/luna_aliases.sh" >> ~/.bashrc
        print_success "Aliases added to ~/.bashrc"
    else
        print_status "Aliases already in ~/.bashrc"
    fi
    
    # Make executable
    chmod +x "$PROJECT_DIR/luna_aliases.sh"
    
    print_success "Aliases created. Run 'source ~/.bashrc' to activate them."
}

# Create systemd services for auto-start
create_systemd_service() {
    print_status "Creating systemd service for auto-start..."
    
    sudo tee /etc/systemd/system/luna.service > /dev/null << EOF
[Unit]
Description=LUNA - Local Understanding & Note Assistant
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable luna.service
    
    print_success "Systemd service created and enabled"
}

# Create configuration and documentation
create_docs() {
    print_status "Creating documentation..."
    
    cat > "$PROJECT_DIR/README.md" << 'EOF'
# LUNA - Local Understanding & Note Assistant

Your personal AI-powered knowledge management companion.

## About LUNA

LUNA is a complete self-hosted knowledge management system that combines:
- Intelligent note-taking with auto-linking
- Voice-to-text transcription  
- AI-powered text enhancement
- Instant search across all your knowledge
- Cross-platform access via web interface

## Components

- **Trilium Notes**: Web-based note-taking and knowledge management
- **Ollama**: Local LLM for text enhancement and generation
- **Whisper**: Voice-to-text transcription
- **Custom API**: Integration layer for all components

## Access Points

- **Trilium Web Interface**: http://your-pi-ip:9876
- **API Endpoints**: http://your-pi-ip:9878
- **Ollama API**: http://your-pi-ip:9877
- **Direct Docker Access**: `docker exec -it trilium bash`

## Quick Commands

### Start LUNA
```bash
cd ~/luna
docker-compose up -d
```

### Stop LUNA
```bash
cd ~/luna
docker-compose down
```

### Talk to LUNA (voice note)
```bash
python ~/luna/scripts/voice_note.py --enhance --duration 30
```

### Quick note to LUNA
```bash
python ~/luna/scripts/quick_note.py "Your note content here" --enhance
```

### Check logs
```bash
docker-compose logs -f
```

## API Endpoints

- `POST /voice-to-text` - Convert audio to text
- `POST /enhance-text` - Enhance text with AI
- `POST /create-note` - Create a new note
- `POST /quick-note` - Quick note creation (voice or text)
- `GET /search?q=query` - Search notes

## Configuration

Edit `docker-compose.yml` to customize:
- Port numbers
- Volume mounts
- Environment variables
- Resource limits

## Backup

Important directories to backup:
- `~/trilium-data` - All your notes and data
- `~/knowledge-base` - Configuration and scripts

## Troubleshooting

1. **Can't access Trilium**: Check if port 9876 is open and not blocked by firewall
2. **API not responding**: Check logs with `docker-compose logs luna-api`
3. **LLM too slow**: Consider using a smaller model in Ollama
4. **Voice notes not working**: Check microphone permissions
5. **Port conflicts**: The ports 9876-9878 are chosen to avoid conflicts

EOF

    cat > "$PROJECT_DIR/.env.example" << 'EOF'
# Example environment configuration
# Copy to .env and customize

# Trilium Configuration
TRILIUM_PORT=9876
TRILIUM_DATA_DIR=/home/pi/trilium-data

# Ollama Configuration
OLLAMA_PORT=9877
OLLAMA_MODEL=llama3.2:3b

# API Configuration
API_PORT=9878
LOG_LEVEL=INFO

# Whisper Configuration
WHISPER_MODEL=base

# Network Configuration
SUBNET=172.20.0.0/16
EOF

    print_success "Documentation created"
}

# Install Ollama model
install_ollama_model() {
    print_status "Setting up Ollama model ($OLLAMA_MODEL)..."
    
    # Wait for Ollama to be ready
    echo "Waiting for Ollama to start..."
    
    # Check if Ollama is ready (with timeout)
    for i in {1..60}; do
        if docker exec ollama ollama list &> /dev/null; then
            break
        fi
        sleep 2
    done
    
    # Pull the model based on system capabilities
    print_status "Pulling $OLLAMA_MODEL (this may take a while)..."
    docker exec ollama ollama pull "$OLLAMA_MODEL"
    
    print_success "Ollama model $OLLAMA_MODEL installed"
}

# Main installation function
main() {
    print_status "Starting LUNA installation..."
    
    check_system
    install_docker
    install_docker_compose
    create_directories
    create_docker_compose
    create_api_service
    create_scripts
    create_trilium_integration
    create_aliases
    create_docs
    
    # Copy cleanup script if it exists
    if [ -f "$(dirname "$0")/luna_cleanup.sh" ]; then
        cp "$(dirname "$0")/luna_cleanup.sh" "$PROJECT_DIR/"
        chmod +x "$PROJECT_DIR/luna_cleanup.sh"
        print_success "Cleanup script installed"
    fi
    
    print_status "Starting services..."
    cd "$PROJECT_DIR"
    
    # Use the appropriate docker compose command
    if [ -n "$DOCKER_COMPOSE_CMD" ]; then
        $DOCKER_COMPOSE_CMD up -d
    else
        docker-compose up -d
    fi
    
    # Wait a bit for services to start
    sleep 10
    
    install_ollama_model
    create_systemd_service
    
    print_success "LUNA installation completed!"
    echo
    echo "🌙 LUNA is ready to assist you!"
    echo
    echo "Access Points:"
    echo "  📝 Trilium Notes: http://$(hostname -I | awk '{print $1}'):9876"
    echo "  🤖 LUNA API: http://$(hostname -I | awk '{print $1}'):9878"
    echo "  🤯 Ollama API: http://$(hostname -I | awk '{print $1}'):9877"
    echo
    echo "Talk to LUNA:"
    echo "  source ~/.bashrc          # Load aliases (first time only)"
    echo "  luna-voice --enhance     # Record a voice note"
    echo "  luna-note 'Hello LUNA!'  # Create a text note"
    echo "  luna-test                # Test API health"
    echo "  luna-status              # Check service status"
    echo
    echo "🔗 API Documentation:"
    echo "  See: $PROJECT_DIR/trilium-integration/API_DOCS.md"
    echo "  Use Luna API endpoints to integrate AI with your applications"
    echo
    echo "Documentation: $PROJECT_DIR/README.md"
    echo "Logs: luna-logs (or docker-compose logs -f)"
    echo
    print_warning "First time setup may take a few minutes for LUNA to initialize"
    print_warning "Run 'source ~/.bashrc' to activate the aliases"
}

# Handle script arguments
show_help() {
    echo "LUNA Setup Script"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  install    Install LUNA (default)"
    echo "  cleanup    Remove LUNA completely from system"
    echo "  update     Update LUNA components"
    echo "  status     Check LUNA installation status"
    echo "  --help     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Install LUNA"
    echo "  $0 cleanup      # Remove LUNA"
    echo "  $0 status       # Check status"
}

# Check status function
check_status() {
    print_status "Checking LUNA installation status..."
    echo
    
    # Check Docker
    if command -v docker &> /dev/null; then
        print_success "Docker: Installed ($(docker --version))"
    else
        print_error "Docker: Not installed"
    fi
    
    # Check Docker Compose
    if docker compose version &> /dev/null; then
        print_success "Docker Compose: v2 installed"
    elif command -v docker-compose &> /dev/null; then
        print_success "Docker Compose: v1 installed"
    else
        print_error "Docker Compose: Not installed"
    fi
    
    # Check containers
    if [ -d "$PROJECT_DIR" ] && [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
        print_status "LUNA containers:"
        cd "$PROJECT_DIR"
        docker-compose ps 2>/dev/null || docker compose ps 2>/dev/null || echo "  Unable to check container status"
    else
        print_warning "LUNA not installed at $PROJECT_DIR"
    fi
    
    # Check systemd service
    if [ -f "/etc/systemd/system/luna.service" ]; then
        print_success "Systemd service: Installed"
        sudo systemctl status luna.service --no-pager | head -5
    else
        print_warning "Systemd service: Not installed"
    fi
}

# Update function
update_luna() {
    print_status "Updating LUNA..."
    
    if [ ! -d "$PROJECT_DIR" ]; then
        print_error "LUNA not installed. Run '$0 install' first."
        exit 1
    fi
    
    cd "$PROJECT_DIR"
    
    # Pull latest images
    print_status "Pulling latest Docker images..."
    docker pull zadam/trilium:latest
    docker pull ollama/ollama:latest
    
    # Restart services
    print_status "Restarting services..."
    if [ -n "$DOCKER_COMPOSE_CMD" ]; then
        $DOCKER_COMPOSE_CMD down
        $DOCKER_COMPOSE_CMD up -d
    else
        docker-compose down
        docker-compose up -d
    fi
    
    print_success "LUNA updated successfully!"
}

# Parse command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    cleanup|uninstall|remove)
        # Run cleanup script if it exists
        if [ -f "$PROJECT_DIR/luna_cleanup.sh" ]; then
            bash "$PROJECT_DIR/luna_cleanup.sh"
        elif [ -f "$(dirname "$0")/luna_cleanup.sh" ]; then
            bash "$(dirname "$0")/luna_cleanup.sh"
        else
            print_error "Cleanup script not found. Please download luna_cleanup.sh"
            echo "You can get it from the LUNA repository"
        fi
        ;;
    status)
        check_status
        ;;
    update)
        check_system
        update_luna
        ;;
    --help|help)
        show_help
        ;;
    *)
        print_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
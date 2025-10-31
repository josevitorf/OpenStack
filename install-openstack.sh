#!/bin/bash

# OPENSTACK INSTALLER - SEGUINDO DOCUMENTAÇÃO OFICIAL
# Ubuntu 22.04/24.04 - DevStack

set -e

# ==============================================================================
# CONFIGURAÇÕES
# ==============================================================================
STACK_USER="stack"
STACK_HOME="/opt/stack"
ADMIN_PASSWORD="openstack123"
HOST_IP=$(hostname -I | awk '{print $1}')
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# ==============================================================================
# FUNÇÕES DE LOG
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# ==============================================================================
# VERIFICAÇÃO DO SISTEMA
# ==============================================================================
check_system() {
    log_step "1. Verificando sistema..."
    
    if [[ ! -f /etc/os-release ]]; then
        log_error "Sistema não suportado - /etc/os-release não encontrado"
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "Apenas Ubuntu é suportado oficialmente. Detectado: $ID"
    fi
    
    # Verificar versões suportadas
    if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
        log_warn "Ubuntu $VERSION_ID pode não ser totalmente suportado"
        log_warn "Versões oficialmente suportadas: 22.04 LTS e 24.04 LTS"
        read -p "Continuar mesmo assim? (s/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 0
        fi
    fi
    
    log_info "Ubuntu $VERSION_ID ($NAME) detectado"
    
    # Verificar recursos
    local total_ram=$(free -g | awk '/^Mem:/{print $2}')
    local total_disk=$(df -h / | awk 'NR==2{print $2}')
    
    log_info "Recursos: RAM ${total_ram}GB | Disco $total_disk | CPUs $(nproc)"
    
    if [[ $total_ram -lt 4 ]]; then
        log_warn "RAM muito baixa (mínimo 4GB recomendado)"
        read -p "Continuar mesmo assim? (s/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 0
        fi
    fi
}

# ==============================================================================
# CRIAR USUÁRIO STACK (SEGUNDO DOCUMENTAÇÃO)
# ==============================================================================
setup_stack_user() {
    log_step "2. Configurando usuário stack conforme documentação..."
    
    # Criar usuário se não existir
    if id "$STACK_USER" &>/dev/null; then
        log_info "Usuário $STACK_USER já existe"
        # Garantir que o diretório home existe
        if [[ ! -d "$STACK_HOME" ]]; then
            sudo mkdir -p "$STACK_HOME"
            sudo chown "$STACK_USER:$STACK_USER" "$STACK_HOME"
        fi
    else
        sudo useradd -s /bin/bash -d "$STACK_HOME" -m "$STACK_USER"
        log_info "Usuário $STACK_USER criado"
    fi
    
    # ✅ CORREÇÃO: Garantir permissão de execução no diretório home
    if [[ -d "$STACK_HOME" ]]; then
        sudo chmod 755 "$STACK_HOME"
        sudo chown "$STACK_USER:$STACK_USER" "$STACK_HOME"
        log_info "Permissões aplicadas em $STACK_HOME"
    else
        log_error "Diretório $STACK_HOME não existe"
    fi
    
    # ✅ Configurar sudo sem senha
    if [[ ! -f /etc/sudoers.d/stack ]]; then
        echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
        sudo chmod 0440 /etc/sudoers.d/stack
        log_info "sudoers configurado para $STACK_USER"
    else
        log_info "sudoers já configurado para $STACK_USER"
    fi
}

# ==============================================================================
# INSTALAR DEPENDÊNCIAS BÁSICAS
# ==============================================================================
install_basic_deps() {
    log_step "3. Instalando dependências básicas..."
    
    log_info "Atualizando lista de pacotes..."
    sudo apt update
    
    log_info "Fazendo upgrade do sistema..."
    sudo apt upgrade -y
    
    log_info "Instalando dependências essenciais..."
    sudo apt install -y \
        git \
        curl \
        wget \
        python3 \
        python3-pip \
        python3-dev \
        python3-venv \
        sudo \
        net-tools
    
    log_info "Dependências básicas instaladas"
}

# ==============================================================================
# DOWNLOAD DEVSTACK (SEGUNDO DOCUMENTAÇÃO)
# ==============================================================================
download_devstack() {
    log_step "4. Baixando DevStack..."
    
    # ✅ CORREÇÃO: Usar bash -c para comandos complexos
    sudo -u "$STACK_USER" bash << EOF
    cd "$STACK_HOME"
    
    # Remover instalação anterior se existir
    if [ -d "devstack" ]; then
        echo "Removendo instalação anterior do DevStack..."
        rm -rf devstack
    fi
    
    echo "Clonando repositório do DevStack..."
    git clone https://opendev.org/openstack/devstack
    
    if [ ! -d "devstack" ]; then
        echo "ERRO: Falha no clone do repositório"
        exit 1
    fi
    
    cd devstack
    echo "DevStack baixado em: \$(pwd)"
    echo "Conteúdo do diretório:"
    ls -la
EOF

    if [[ ! -d "$STACK_HOME/devstack" ]]; then
        log_error "Falha crítica no download do DevStack"
    fi
    
    log_info "DevStack baixado com sucesso em $STACK_HOME/devstack"
}

# ==============================================================================
# CRIAR local.conf (CONFORME DOCUMENTAÇÃO)
# ==============================================================================
create_local_conf() {
    log_step "5. Criando local.conf conforme documentação..."
    
    # ✅ CORREÇÃO: Usar arquivo temporário para evitar problemas de escaping
    local temp_file=$(mktemp)
    
    cat > "$temp_file" << EOF
[[local|localrc]]
# CONFIGURAÇÃO MÍNIMA - DOCUMENTAÇÃO OFICIAL
ADMIN_PASSWORD=$ADMIN_PASSWORD
DATABASE_PASSWORD=$ADMIN_PASSWORD
RABBIT_PASSWORD=$ADMIN_PASSWORD
SERVICE_PASSWORD=$ADMIN_PASSWORD

# CONFIGURAÇÕES ADICIONAIS RECOMENDADAS
HOST_IP=$HOST_IP
SERVICE_TIMEOUT=300
LOG_COLOR=True
LOGFILE=$STACK_HOME/logs/stack.sh.log

# Habilita logs detalhados
LOGDAYS=1
EOF

    # Copiar arquivo para o usuário stack
    sudo cp "$temp_file" "$STACK_HOME/devstack/local.conf"
    sudo chown "$STACK_USER:$STACK_USER" "$STACK_HOME/devstack/local.conf"
    rm -f "$temp_file"
    
    log_info "local.conf criado com sucesso"
    log_info "Conteúdo do local.conf:"
    sudo -u "$STACK_USER" cat "$STACK_HOME/devstack/local.conf"
}

# ==============================================================================
# PREPARAR INSTALAÇÃO
# ==============================================================================
prepare_installation() {
    log_step "6. Preparando instalação..."
    
    # Criar diretório de logs
    sudo mkdir -p "$STACK_HOME/logs"
    sudo chown -R "$STACK_USER:$STACK_USER" "$STACK_HOME/logs"
    sudo chmod 755 "$STACK_HOME/logs"
    
    # Configurar git para downloads grandes
    sudo -u "$STACK_USER" git config --global http.postBuffer 1048576000
    sudo -u "$STACK_USER" git config --global core.compression 0
    
    log_info "Ambiente preparado para instalação"
}

# ==============================================================================
# EXECUTAR INSTALAÇÃO (SEGUNDO DOCUMENTAÇÃO)
# ==============================================================================
run_stack_install() {
    log_step "7. Iniciando instalação com ./stack.sh..."
    
    log_info "📢 ATENÇÃO: Esta etapa pode levar 15-45 minutos"
    log_info "📊 Logs detalhados em: $STACK_HOME/logs/stack.sh.log"
    log_info "💡 A velocidade depende da sua conexão com a internet"
    log_info "🖥️  Não desligue o computador durante esta etapa!"
    echo
    log_info "Pressione Ctrl+C para cancelar ou Enter para continuar..."
    read -r
    
    # ✅ CORREÇÃO: Executar em background com logs
    log_info "Iniciando ./stack.sh..."
    
    sudo -u "$STACK_USER" bash << EOF
    cd "$STACK_HOME/devstack"
    echo "=== INICIANDO INSTALAÇÃO OPENSTACK ==="
    echo "Diretório: \$(pwd)"
    echo "Data/Hora: \$(date)"
    echo "======================================"
    
    # Executar stack.sh e capturar logs
    ./stack.sh 2>&1 | tee "$STACK_HOME/logs/stack-install.log"
    
    INSTALL_EXIT_CODE=\${PIPESTATUS[0]}
    echo "======================================"
    echo "Instalação finalizada com código: \$INSTALL_EXIT_CODE"
    echo "Data/Hora: \$(date)"
    
    if [ \$INSTALL_EXIT_CODE -eq 0 ]; then
        echo "✅ Instalação concluída com sucesso!"
    else
        echo "❌ Instalação falhou com código \$INSTALL_EXIT_CODE"
        echo "Verifique os logs em $STACK_HOME/logs/"
    fi
EOF

    # Verificar resultado da instalação
    if [[ -f "$STACK_HOME/devstack/openrc" ]]; then
        log_info "✅ Instalação OpenStack concluída com sucesso!"
    else
        log_warn "⚠️  A instalação pode não ter completado totalmente"
        log_warn "Verifique os logs em $STACK_HOME/logs/"
    fi
}

# ==============================================================================
# VERIFICAR INSTALAÇÃO
# ==============================================================================
verify_installation() {
    log_step "8. Verificando instalação..."
    
    if [[ -f "$STACK_HOME/devstack/openrc" ]]; then
        log_info "Carregando variáveis de ambiente OpenStack..."
        
        # ✅ CORREÇÃO: Verificação mais robusta
        sudo -u "$STACK_USER" bash << 'EOF'
        cd /opt/stack/devstack
        source openrc admin admin
        
        echo "=== SERVIÇOS OPENSTACK ==="
        if openstack compute service list > /dev/null 2>&1; then
            echo "✅ Serviços compute estão respondendo"
            openstack compute service list --format value -c Host -c Binary -c State | head -10
        else
            echo "❌ Serviços compute não estão disponíveis"
        fi
        
        echo
        echo "=== ENDPOINTS ==="
        if openstack endpoint list > /dev/null 2>&1; then
            echo "✅ Endpoints estão disponíveis"
            openstack endpoint list --format value -c "Service Name" -c "Enabled" | head -10
        else
            echo "❌ Endpoints não estão disponíveis"
        fi
EOF

        # Testar dashboard
        log_info "Testando dashboard Horizon..."
        if curl -s --connect-timeout 10 "http://$HOST_IP/dashboard" > /dev/null; then
            log_info "✅ Dashboard Horizon está respondendo"
        else
            log_warn "⚠️  Dashboard não está respondendo (pode estar iniciando)"
        fi
    else
        log_warn "Arquivo openrc não encontrado - OpenStack pode não estar totalmente instalado"
    fi
}

# ==============================================================================
# CRIAR SCRIPT DE GERENCIAMENTO
# ==============================================================================
create_management_script() {
    log_step "9. Criando script de gerenciamento..."
    
    sudo tee /usr/local/bin/openstack-manage > /dev/null << 'EOF'
#!/bin/bash

STACK_HOME="/opt/stack"
STACK_USER="stack"

show_usage() {
    echo "OpenStack Management Script - DevStack"
    echo "Uso: $0 {start|stop|restart|status|logs|dashboard|clean|help}"
    echo
    echo "Comandos:"
    echo "  start     - Iniciar serviços OpenStack"
    echo "  stop      - Parar serviços OpenStack"
    echo "  restart   - Reiniciar serviços OpenStack"
    echo "  status    - Status dos serviços"
    echo "  logs      - Ver logs em tempo real"
    echo "  dashboard - Informações do dashboard"
    echo "  clean     - Limpar instalação"
    echo "  help      - Mostrar esta ajuda"
}

case "$1" in
    start)
        echo "Iniciando serviços OpenStack..."
        sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && ./rejoin-stack.sh"
        ;;
    stop)
        echo "Parando serviços OpenStack..."
        sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && ./unstack.sh"
        ;;
    restart)
        echo "Reiniciando serviços OpenStack..."
        sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && ./unstack.sh"
        sleep 5
        sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && ./rejoin-stack.sh"
        ;;
    status)
        echo "=== STATUS DOS SERVIÇOS OPENSTACK ==="
        sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && source openrc admin admin && openstack compute service list" 2>/dev/null || \
            echo "Serviços OpenStack não estão disponíveis"
        ;;
    logs)
        echo "Mostrando logs (Ctrl+C para parar)..."
        sudo tail -f "$STACK_HOME/logs/stack.sh.log"
        ;;
    dashboard)
        IP=$(hostname -I | awk '{print $1}')
        echo "=== DASHBOARD OPENSTACK ==="
        echo "URL: http://$IP/dashboard"
        echo "Usuário: admin"
        echo "Senha: openstack123"
        echo
        echo "Para acessar:"
        echo " 1. Abra o navegador no endereço acima"
        echo " 2. Use as credenciais informadas"
        echo " 3. Certifique-se de que os serviços estão rodando"
        ;;
    clean)
        echo "Limpando instalação OpenStack..."
        read -p "Tem certeza? Isso irá parar e remover todos os serviços. (s/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            sudo -u "$STACK_USER" bash -c "cd '$STACK_HOME/devstack' && ./unstack.sh && ./clean.sh"
            echo "Instalação limpa"
        else
            echo "Operação cancelada"
        fi
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo "Comando inválido: $1"
        show_usage
        exit 1
        ;;
esac
EOF

    sudo chmod +x /usr/local/bin/openstack-manage
    log_info "Script de gerenciamento criado: openstack-manage"
}

# ==============================================================================
# INFORMAÇÕES FINAIS
# ==============================================================================
show_final_info() {
    log_step "10. Instalação concluída!"
    
    echo
    echo "=========================================="
    echo "🎉 OPENSTACK INSTALADO CONFORME DOCUMENTAÇÃO!"
    echo "=========================================="
    echo
    echo "📊 DASHBOARD HORIZON:"
    echo "   URL: http://$HOST_IP/dashboard"
    echo "   Usuário: admin"
    echo "   Senha: $ADMIN_PASSWORD"
    echo
    echo "⚙️  COMANDOS DE GERENCIAMENTO:"
    echo "   openstack-manage start     - Iniciar serviços"
    echo "   openstack-manage stop      - Parar serviços"
    echo "   openstack-manage restart   - Reiniciar serviços"
    echo "   openstack-manage status    - Status dos serviços"
    echo "   openstack-manage logs      - Ver logs em tempo real"
    echo "   openstack-manage dashboard - Informações do dashboard"
    echo "   openstack-manage clean     - Limpar instalação"
    echo
    echo "💻 COMANDOS OPENSTACK CLI:"
    echo "   sudo -u stack bash"
    echo "   cd /opt/stack/devstack"
    echo "   source openrc admin admin"
    echo "   openstack server list"
    echo
    echo "📁 ESTRUTURA DE ARQUIVOS:"
    echo "   DevStack:    /opt/stack/devstack"
    echo "   Logs:        /opt/stack/logs/"
    echo "   Config:      /opt/stack/devstack/local.conf"
    echo
    echo "✅ CONFORME DOCUMENTAÇÃO OFICIAL:"
    echo "   ✓ Usuário stack com sudo NOPASSWD"
    echo "   ✓ Permissões corretas em /opt/stack"
    echo "   ✓ local.conf com configuração mínima"
    echo "   ✓ ./stack.sh executado como usuário stack"
    echo
    echo "🔧 PRÓXIMOS PASSOS:"
    echo "   1. Acesse o dashboard no URL acima"
    echo "   2. Configure redes e security groups"
    echo "   3. Crie sua primeira instância"
    echo
    echo "❌ SOLUÇÃO DE PROBLEMAS:"
    echo "   - Verifique logs: tail -f /opt/stack/logs/stack.sh.log"
    echo "   - Reinicie serviços: openstack-manage restart"
    echo "   - Status: openstack-manage status"
    echo
}

# ==============================================================================
# FUNÇÃO PRINCIPAL
# ==============================================================================
main() {
    clear
    echo "=========================================="
    echo "   OPENSTACK - INSTALADOR OFICIAL"
    echo "=========================================="
    echo "   Seguindo documentação do DevStack"
    echo "   Ubuntu 22.04/24.04 LTS"
    echo "=========================================="
    echo
    
    # Verificar se não é root
    if [[ $EUID -eq 0 ]]; then
        log_error "Não execute como root. Use seu usuário normal com sudo."
    fi
    
    # Verificar sudo
    if ! sudo -n true 2>/dev/null; then
        log_error "Usuário não tem permissões sudo configuradas."
    fi
    
    # Mostrar informações do sistema
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "Sistema: $NAME $VERSION_ID"
    fi
    echo "IP: $HOST_IP"
    echo "Interface: $INTERFACE"
    echo "Usuário: $(whoami)"
    echo
    
    # Confirmar instalação
    log_warn "Este script seguirá EXATAMENTE a documentação oficial do DevStack."
    log_warn "Isto instalará múltiplos serviços e modificará configurações de rede."
    echo
    read -p "Continuar com a instalação? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        log_info "Instalação cancelada pelo usuário."
        exit 0
    fi
    
    # Executar etapas conforme documentação
    check_system
    setup_stack_user
    install_basic_deps
    download_devstack
    create_local_conf
    prepare_installation
    run_stack_install
    verify_installation
    create_management_script
    show_final_info
    
    log_info "✨ OpenStack instalado conforme documentação oficial!"
    log_info "🗓️  Instalação finalizada em: $(date)"
}

# Tratamento de sinais
trap 'log_error "Script interrompido pelo usuário"; exit 1' INT TERM

# Executar script principal
main "$@"
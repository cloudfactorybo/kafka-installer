#!/bin/bash
# ============================================================
# Script de instalación de Kafka Seguro con TLS + SASL
# PLAINTEXT interno + SASL_SSL para clientes externos
# Genera: Certificados, docker-compose.yml, kafka_server_jaas.conf
#
# SAN dinámico: detecta las IPs locales del host y las agrega
# al certificado, además de la IP principal y nombres DNS extra.
# ============================================================

set -e

main() {

# ── Si se ejecuta con "curl ... | bash", leer las respuestas desde la terminal ──
if [ ! -t 0 ] && (: < /dev/tty) 2>/dev/null; then exec < /dev/tty; fi

stty erase ^H 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "   ${GREEN}✅ $1${NC}"; }
warn() { echo -e "   ${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "   ${RED}❌ $1${NC}"; exit 1; }

# ── Argumentos ──────────────────────────────────────────────
KAFKA_VERSION="${KAFKA_VERSION:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --version) KAFKA_VERSION="$2"; shift 2 ;;
        --version=*) KAFKA_VERSION="${1#*=}"; shift ;;
        -h|--help)
            echo "Uso: sudo ./install-kafka-seguro.sh [--version X.Y.Z]"
            echo "  --version   Versión de confluentinc/cp-kafka (por defecto: la última estable)"
            echo "  Variables:  KAFKA_VERSION=X.Y.Z  (equivale a --version)"
            exit 0 ;;
        *) echo "Opción desconocida: $1 (usa --help)"; exit 1 ;;
    esac
done

echo -e "${BLUE}"
echo "============================================================"
echo "   🔐 CONFIGURACIÓN DE KAFKA SEGURO (TLS + SASL)"
echo "   ⚡ PLAINTEXT interno + SASL_SSL externo"
echo "============================================================"
echo -e "${NC}"

# ============================================================
# ── VERIFICACIÓN DEL SISTEMA ────────────────────────────────
# ============================================================
echo -e "${YELLOW}🔎 VERIFICANDO EL SISTEMA${NC}"

[ "$(uname -s)" = "Linux" ] || fail "Sistema no soportado: $(uname -s). Solo Linux."
case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) fail "Arquitectura no soportada: $(uname -m). Solo amd64 y arm64." ;;
esac
ok "Plataforma: linux/${ARCH}"

[ "$(id -u)" -eq 0 ] || warn "No se ejecuta como root: las claves no podrán restringirse a uid 1000 (usa sudo)."

command -v docker  >/dev/null 2>&1 || fail "Docker no está instalado. Instálalo: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1        || fail "No se puede hablar con Docker (¿daemon apagado o falta sudo?)."
docker compose version >/dev/null 2>&1 || fail "Falta el plugin 'docker compose' (v2)."
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) + $(docker compose version --short 2>/dev/null | sed 's/^/compose /')"

command -v openssl >/dev/null 2>&1 || fail "Falta openssl (apt install openssl)."
ok "$(openssl version | cut -d' ' -f1-2)"

if command -v curl >/dev/null 2>&1; then HTTP_GET="curl -fsSL --max-time 10"
elif command -v wget >/dev/null 2>&1; then HTTP_GET="wget -qO- --timeout=10"
else HTTP_GET=""; warn "Sin curl ni wget: no se podrá consultar la última versión de Kafka."; fi

if command -v keytool >/dev/null 2>&1; then
    USE_DOCKER_KEYTOOL=0; ok "keytool local disponible"
else
    USE_DOCKER_KEYTOOL=1; warn "keytool no instalado: se usará el de la imagen de Kafka (no hace falta Java)."
fi

# ============================================================
# ── VERSIÓN DE KAFKA ────────────────────────────────────────
# ============================================================
KAFKA_REPO="confluentinc/cp-kafka"
FALLBACK_VERSION="7.9.0"

ultima_version() {
    [ -z "$HTTP_GET" ] && return 1
    $HTTP_GET "https://hub.docker.com/v2/namespaces/confluentinc/repositories/cp-kafka/tags?page_size=100" 2>/dev/null \
        | grep -oE '"name": *"[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | sort -V | tail -1
}

echo ""
echo -e "${YELLOW}🐳 VERSIÓN DE KAFKA${NC}"
if [ -n "$KAFKA_VERSION" ]; then
    ok "Versión indicada: ${KAFKA_VERSION}"
else
    DETECTADA=$(ultima_version || true)
    if [ -n "$DETECTADA" ]; then
        ok "Última versión estable en Docker Hub: ${DETECTADA}"
    else
        DETECTADA=$(docker image ls "$KAFKA_REPO" --format '{{.Tag}}' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        DETECTADA=${DETECTADA:-$FALLBACK_VERSION}
        warn "No se pudo consultar Docker Hub; se propone ${DETECTADA}"
    fi
    read -p "Versión de cp-kafka a usar [${DETECTADA}]: " KAFKA_VERSION
    KAFKA_VERSION=${KAFKA_VERSION:-$DETECTADA}
fi
[[ $KAFKA_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Versión inválida: ${KAFKA_VERSION} (formato X.Y.Z)"
KAFKA_IMAGE="${KAFKA_REPO}:${KAFKA_VERSION}"

echo -e "   ⬇️  Descargando ${KAFKA_IMAGE} (puede tardar)..."
docker pull -q "$KAFKA_IMAGE" >/dev/null || fail "No se pudo descargar ${KAFKA_IMAGE}"
ok "Imagen lista: ${KAFKA_IMAGE}"

# ============================================================
# ── INSTALACIÓN EXISTENTE ───────────────────────────────────
# ============================================================
BASE_DIR="$(pwd)"
REUSE_CA="n"
if [ -f "${BASE_DIR}/docker-compose.yml" ] || [ -d "${BASE_DIR}/certs" ]; then
    echo ""
    echo -e "${YELLOW}📦 INSTALACIÓN EXISTENTE DETECTADA en ${BASE_DIR}${NC}"
    BACKUP_DIR="${BASE_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    for f in docker-compose.yml kafka_server_jaas.conf client.properties client-verificado.properties server-ext.cnf certs; do
        [ -e "${BASE_DIR}/$f" ] && cp -a "${BASE_DIR}/$f" "$BACKUP_DIR/"
    done
    chmod 700 "$BACKUP_DIR"
    ok "Respaldo creado en ${BACKUP_DIR}"
    if ls "${BASE_DIR}"/certs/*-ca-key.pem >/dev/null 2>&1; then
        echo "   Si reutilizas la CA, los clientes (Logstash, agentes) NO necesitan un truststore nuevo."
        read -p "   ¿Reutilizar la CA existente? (S/n): " REUSE_CA
        REUSE_CA=${REUSE_CA:-S}
    fi
fi

echo ""
echo -e "${YELLOW}📋 INFORMACIÓN GENERAL${NC}"
DEF_EMPRESA=$(ls "${BASE_DIR}"/certs/*-ca-cert.pem 2>/dev/null | head -1 | xargs -r basename | sed 's/-ca-cert.pem$//')
DEF_EMPRESA=${DEF_EMPRESA:-kafka}
read -p "Nombre de la empresa/proyecto [${DEF_EMPRESA}]: " EMPRESA
EMPRESA=${EMPRESA:-$DEF_EMPRESA}
EMPRESA=$(echo "$EMPRESA" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

DEF_HOST=$(hostname -s 2>/dev/null || echo kafka)
read -p "Hostname del servidor [${DEF_HOST}]: " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEF_HOST}

DEF_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
read -p "IP del servidor [${DEF_IP}]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$DEF_IP}
while [[ ! $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
    echo -e "${RED}❌ IP inválida. Intenta de nuevo.${NC}"
    read -p "IP del servidor: " SERVER_IP
done

# ============================================================
# ── DETECCIÓN DE IPs LOCALES PARA EL SAN ────────────────────
# ============================================================
echo ""
echo -e "${YELLOW}🌐 DETECCIÓN DE IPs LOCALES${NC}"

# Interfaces que se ignoran por defecto (virtuales de Docker/K8s)
IGNORAR_IFACE="docker|br-|veth|virbr|cni|flannel|kube|tun|tap|zt"

detectar_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $2" "$4}' \
            | grep -Ev "^($IGNORAR_IFACE)" \
            | awk '{print $2}' | cut -d/ -f1
    else
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.'
    fi
}

# Las IPs virtuales van aparte, por si el usuario sí las quiere
detectar_ips_virtuales() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $2" "$4}' \
            | grep -E "^($IGNORAR_IFACE)" \
            | awk '{print $2}' | cut -d/ -f1
    fi
}

IPS_DETECTADAS=$(detectar_ips | sort -u)
IPS_VIRTUALES=$(detectar_ips_virtuales | sort -u)

if [ -n "$IPS_DETECTADAS" ]; then
    echo -e "   ${GREEN}IPs físicas detectadas:${NC}"
    echo "$IPS_DETECTADAS" | sed 's/^/      • /'
else
    echo -e "   ${YELLOW}⚠️  No se detectaron IPs adicionales${NC}"
fi

if [ -n "$IPS_VIRTUALES" ]; then
    echo -e "   ${YELLOW}IPs virtuales (Docker/bridges) omitidas por defecto:${NC}"
    echo "$IPS_VIRTUALES" | sed 's/^/      • /'
fi

echo ""
read -p "¿Incluir las IPs físicas detectadas en el certificado? (S/n): " INC_LOCALES
INC_LOCALES=${INC_LOCALES:-S}

INC_VIRTUALES="n"
if [ -n "$IPS_VIRTUALES" ]; then
    read -p "¿Incluir también las IPs virtuales/Docker? (s/N): " INC_VIRTUALES
    INC_VIRTUALES=${INC_VIRTUALES:-n}
fi

echo ""
read -p "IPs adicionales separadas por espacio (NAT, VPN, balanceador — Enter para omitir): " IPS_EXTRA
read -p "Nombres DNS adicionales separados por espacio (Enter para omitir): " DNS_EXTRA

echo ""
echo -e "${YELLOW}📣 HOST ANUNCIADO A LOS CLIENTES (advertised.listeners)${NC}"
echo "   Kafka le dice a cada cliente a qué dirección reconectarse después del bootstrap."
echo "   Si hay clientes detrás de NAT, usa un NOMBRE (no una IP) y que cada cliente"
echo "   lo resuelva a la IP que le sirve (/etc/hosts o extra_hosts en Docker)."
read -p "Host anunciado para SASL_SSL [${HOSTNAME}]: " ADVERTISED_HOST
ADVERTISED_HOST=${ADVERTISED_HOST:-$HOSTNAME}

# ── Armado de las listas SAN ────────────────────────────────
SAN_DNS_LIST="localhost $HOSTNAME kafka kafka-${EMPRESA}"
SAN_IP_LIST="127.0.0.1 $SERVER_IP"

if [[ "$INC_LOCALES" =~ ^[Ss] ]] && [ -n "$IPS_DETECTADAS" ]; then
    SAN_IP_LIST="$SAN_IP_LIST $(echo $IPS_DETECTADAS)"
fi

if [[ "$INC_VIRTUALES" =~ ^[Ss] ]] && [ -n "$IPS_VIRTUALES" ]; then
    SAN_IP_LIST="$SAN_IP_LIST $(echo $IPS_VIRTUALES)"
fi

# Validar y agregar las IPs extra escritas a mano
for ip in $IPS_EXTRA; do
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        SAN_IP_LIST="$SAN_IP_LIST $ip"
    else
        echo -e "   ${RED}⚠️  IP ignorada por formato inválido: $ip${NC}"
    fi
done

for d in $DNS_EXTRA; do
    SAN_DNS_LIST="$SAN_DNS_LIST $d"
done

# El host anunciado siempre debe estar en el certificado
if [[ $ADVERTISED_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN_IP_LIST="$SAN_IP_LIST $ADVERTISED_HOST"
else
    SAN_DNS_LIST="$SAN_DNS_LIST $ADVERTISED_HOST"
fi

# Deduplicar conservando el orden
SAN_IP_LIST=$(echo $SAN_IP_LIST | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
SAN_DNS_LIST=$(echo $SAN_DNS_LIST | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')

# ============================================================

echo ""
echo -e "${YELLOW}🔑 CREDENCIALES SASL${NC}"
read -p "Usuario SASL (ej: admin): " SASL_USER
SASL_USER=${SASL_USER:-admin}

read -s -p "Contraseña SASL: " SASL_PASSWORD
echo ""
while [[ -z "$SASL_PASSWORD" ]]; do
    echo -e "${RED}❌ La contraseña no puede estar vacía.${NC}"
    read -s -p "Contraseña SASL: " SASL_PASSWORD
    echo ""
done

echo ""
echo -e "${YELLOW}🔒 CONTRASEÑA SSL/TLS${NC}"
read -s -p "Contraseña SSL (mínimo 6 caracteres): " SSL_PASSWORD
echo ""
while [[ ${#SSL_PASSWORD} -lt 6 ]]; do
    echo -e "${RED}❌ La contraseña debe tener al menos 6 caracteres.${NC}"
    read -s -p "Contraseña SSL: " SSL_PASSWORD
    echo ""
done

echo ""
echo -e "${YELLOW}📅 VIGENCIA DE CERTIFICADOS${NC}"
echo "   La CA cuesta cambiarla (hay que redistribuir el truststore a todos los clientes)."
echo "   El certificado del servidor se renueva fácil con ./regenerar-cert.sh."
read -p "Años de vigencia de la CA [10]: " CA_YEARS
CA_YEARS=${CA_YEARS:-10}
read -p "Años de vigencia del certificado del servidor [5]: " SRV_YEARS
SRV_YEARS=${SRV_YEARS:-5}
while ! [[ $CA_YEARS =~ ^[0-9]+$ && $SRV_YEARS =~ ^[0-9]+$ && $SRV_YEARS -le $CA_YEARS && $SRV_YEARS -ge 1 ]]; do
    echo -e "${RED}❌ Deben ser números enteros y el certificado no puede durar más que la CA.${NC}"
    read -p "Años de la CA [10]: " CA_YEARS; CA_YEARS=${CA_YEARS:-10}
    read -p "Años del certificado [5]: " SRV_YEARS; SRV_YEARS=${SRV_YEARS:-5}
done

while true; do
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}📝 RESUMEN DE CONFIGURACIÓN:${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo -e "   1) Empresa/Proyecto:  ${YELLOW}$EMPRESA${NC}"
    echo -e "   2) Hostname:          ${YELLOW}$HOSTNAME${NC}"
    echo -e "   3) IP del servidor:   ${YELLOW}$SERVER_IP${NC}"
    echo -e "   4) Usuario SASL:      ${YELLOW}$SASL_USER${NC}"
    echo -e "   5) Contraseña SASL:   ${YELLOW}********${NC}"
    echo -e "   6) Contraseña SSL:    ${YELLOW}********${NC}"
    echo -e "   7) IPs en el cert:    ${YELLOW}${SAN_IP_LIST}${NC}"
    echo -e "   8) DNS en el cert:    ${YELLOW}${SAN_DNS_LIST}${NC}"
    echo -e "   9) Host anunciado:    ${YELLOW}${ADVERTISED_HOST}:9094${NC}"
    echo -e "  10) Vigencia:          ${YELLOW}CA ${CA_YEARS} años / servidor ${SRV_YEARS} años${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
    read -p "¿Corregir algún dato? (1-10, c=continuar, q=salir): " OPCION

    case $OPCION in
        1) read -p "Nuevo nombre: " EMPRESA; EMPRESA=${EMPRESA:-kafka}; EMPRESA=$(echo "$EMPRESA" | tr '[:upper:]' '[:lower:]' | tr ' ' '-') ;;
        2) read -p "Nuevo hostname: " HOSTNAME; HOSTNAME=${HOSTNAME:-kafka} ;;
        3) read -p "Nueva IP: " SERVER_IP
           while [[ ! $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
               echo -e "${RED}❌ IP inválida.${NC}"; read -p "IP: " SERVER_IP; done ;;
        4) read -p "Nuevo usuario SASL: " SASL_USER; SASL_USER=${SASL_USER:-admin} ;;
        5) read -s -p "Nueva contraseña SASL: " SASL_PASSWORD; echo ""
           while [[ -z "$SASL_PASSWORD" ]]; do echo -e "${RED}❌ No puede estar vacía.${NC}"; read -s -p "Contraseña SASL: " SASL_PASSWORD; echo ""; done ;;
        6) read -s -p "Nueva contraseña SSL: " SSL_PASSWORD; echo ""
           while [[ ${#SSL_PASSWORD} -lt 6 ]]; do echo -e "${RED}❌ Mínimo 6 caracteres.${NC}"; read -s -p "Contraseña SSL: " SSL_PASSWORD; echo ""; done ;;
        7) echo -e "   ${YELLOW}Actual: ${SAN_IP_LIST}${NC}"
           read -p "   Lista completa de IPs separadas por espacio: " NUEVAS_IPS
           TMP_IPS="127.0.0.1 $SERVER_IP"
           for ip in $NUEVAS_IPS; do
               if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                   TMP_IPS="$TMP_IPS $ip"
               else
                   echo -e "   ${RED}⚠️  Ignorada (formato inválido): $ip${NC}"
               fi
           done
           SAN_IP_LIST=$(echo $TMP_IPS | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ;;
        8) echo -e "   ${YELLOW}Actual: ${SAN_DNS_LIST}${NC}"
           read -p "   Lista completa de nombres DNS separados por espacio: " NUEVOS_DNS
           TMP_DNS="localhost $HOSTNAME $NUEVOS_DNS"
           SAN_DNS_LIST=$(echo $TMP_DNS | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ') ;;
        9) read -p "Nuevo host anunciado: " ADVERTISED_HOST; ADVERTISED_HOST=${ADVERTISED_HOST:-$HOSTNAME}
           if [[ $ADVERTISED_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
               SAN_IP_LIST=$(echo $SAN_IP_LIST $ADVERTISED_HOST | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
           else
               SAN_DNS_LIST=$(echo $SAN_DNS_LIST $ADVERTISED_HOST | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
           fi ;;
        10) read -p "Años de la CA: " CA_YEARS; CA_YEARS=${CA_YEARS:-10}
            read -p "Años del certificado del servidor: " SRV_YEARS; SRV_YEARS=${SRV_YEARS:-5}
            if ! [[ $CA_YEARS =~ ^[0-9]+$ && $SRV_YEARS =~ ^[0-9]+$ && $SRV_YEARS -le $CA_YEARS && $SRV_YEARS -ge 1 ]]; then
                echo -e "${RED}❌ Valores inválidos, se restauran 10/5.${NC}"; CA_YEARS=10; SRV_YEARS=5
            fi ;;
        [Cc]) echo -e "${GREEN}✅ Continuando...${NC}"; break ;;
        [Qq]) echo -e "${RED}❌ Cancelado.${NC}"; exit 1 ;;
        *) echo -e "${RED}❌ Opción inválida.${NC}" ;;
    esac
done

# ── Directorio base ──────────────────────────────────────────
CERT_DIR="${BASE_DIR}/certs"
DATA_DIR="${BASE_DIR}/data"

echo ""
echo -e "${GREEN}📁 Creando directorios...${NC}"
mkdir -p "$CERT_DIR" "$DATA_DIR"
chmod 777 "$DATA_DIR"

# ── CLUSTER_ID ───────────────────────────────────────────────
# Si ya hay datos, se reutiliza el ID existente (cambiarlo impide arrancar Kafka).
if [ -f "${DATA_DIR}/meta.properties" ]; then
    CLUSTER_ID=$(grep '^cluster.id=' "${DATA_DIR}/meta.properties" | cut -d= -f2)
    echo -e "   ${YELLOW}ℹ️  Datos existentes: se reutiliza CLUSTER_ID ${CLUSTER_ID}${NC}"
else
    CLUSTER_ID=$(openssl rand 16 | base64 | tr '+/' '-_' | tr -d '=')
fi

# ── Certificados ─────────────────────────────────────────────
echo -e "${GREEN}🔐 Generando certificados TLS...${NC}"

CA_DAYS=$((CA_YEARS * 365))
SRV_DAYS=$((SRV_YEARS * 365))
CA_CERT="${EMPRESA}-ca-cert.pem"
CA_KEY="${EMPRESA}-ca-key.pem"
SERVER_KEY="${EMPRESA}-server-key.pem"
SERVER_CERT="${EMPRESA}-server-cert.pem"
KEYSTORE="kafka.keystore.p12"
TRUSTSTORE="kafka.truststore.p12"

check_ok() {
    if [ $? -ne 0 ]; then echo -e "   ${RED}❌ Error en: $1${NC}"; exit 1; fi
}

CA_REUTILIZADA=0
if [[ "$REUSE_CA" =~ ^[Ss] ]] && [ -f "${CERT_DIR}/${CA_CERT}" ] && [ -f "${CERT_DIR}/${CA_KEY}" ]; then
    if openssl pkey -in "${CERT_DIR}/${CA_KEY}" -passin pass:"${SSL_PASSWORD}" -noout 2>/dev/null; then
        CA_FIN_TS=$(date -d "$(openssl x509 -in "${CERT_DIR}/${CA_CERT}" -noout -enddate | cut -d= -f2)" +%s)
        DIAS_CA=$(( (CA_FIN_TS - $(date +%s)) / 86400 ))
        if [ "$DIAS_CA" -gt 30 ]; then
            CA_REUTILIZADA=1
            echo -e "   ♻️  Reutilizando CA existente (vence en ${DIAS_CA} días)"
            [ "$SRV_DAYS" -gt "$DIAS_CA" ] && SRV_DAYS=$DIAS_CA && warn "Vigencia del servidor recortada a ${SRV_DAYS} días (no puede superar a la CA)."
        else
            warn "La CA existente vence en ${DIAS_CA} días: se genera una nueva."
        fi
    else
        warn "La contraseña SSL no abre la clave de la CA existente: se genera una CA nueva."
        warn "Tendrás que copiar el nuevo truststore a todos los clientes."
    fi
elif [ -f "${CERT_DIR}/${CA_CERT}" ]; then
    warn "Se reemplaza la CA: tendrás que copiar el nuevo truststore a todos los clientes."
fi

if [ "$CA_REUTILIZADA" -eq 0 ]; then
    echo -e "   📜 Creando CA..."
    rm -f "${CERT_DIR}/${CA_CERT}" "${CERT_DIR}/${CA_KEY}"
    openssl req -new -x509 \
        -keyout "${CERT_DIR}/${CA_KEY}" -out "${CERT_DIR}/${CA_CERT}" \
        -days $CA_DAYS -subj "/CN=${EMPRESA}-CA/O=${EMPRESA}/C=US" \
        -passout pass:"${SSL_PASSWORD}" 2>/dev/null
    check_ok "Generación de CA"
fi

echo -e "   🔑 Creando clave del servidor..."
openssl genrsa -out "${CERT_DIR}/${SERVER_KEY}" 2048
check_ok "Clave privada del servidor"

openssl req -new -key "${CERT_DIR}/${SERVER_KEY}" \
    -out "${CERT_DIR}/${EMPRESA}-server.csr" \
    -subj "/CN=${HOSTNAME}/O=${EMPRESA}/C=US"
check_ok "CSR del servidor"

# ── Archivo de extensiones con SAN dinámico ─────────────────
echo -e "   📝 Construyendo SAN del certificado..."

cat > "${CERT_DIR}/server-ext.cnf" << 'EOF'
[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth

[alt_names]
EOF

N=1
for d in $SAN_DNS_LIST; do
    echo "DNS.$N = $d" >> "${CERT_DIR}/server-ext.cnf"
    echo -e "      ${GREEN}DNS.$N${NC} → $d"
    N=$((N+1))
done

N=1
for ip in $SAN_IP_LIST; do
    echo "IP.$N = $ip" >> "${CERT_DIR}/server-ext.cnf"
    echo -e "      ${GREEN}IP.$N${NC}  → $ip"
    N=$((N+1))
done

echo -e "   ✍️  Firmando certificado..."
openssl x509 -req \
    -CA "${CERT_DIR}/${CA_CERT}" -CAkey "${CERT_DIR}/${CA_KEY}" \
    -in "${CERT_DIR}/${EMPRESA}-server.csr" -out "${CERT_DIR}/${SERVER_CERT}" \
    -days $SRV_DAYS -CAcreateserial -passin pass:"${SSL_PASSWORD}" \
    -extfile "${CERT_DIR}/server-ext.cnf" -extensions v3_req
check_ok "Firma del certificado"

echo -e "   📦 Creando keystore..."
rm -f "${CERT_DIR}/${KEYSTORE}" "${CERT_DIR}/${TRUSTSTORE}"
openssl pkcs12 -export \
    -in "${CERT_DIR}/${SERVER_CERT}" -inkey "${CERT_DIR}/${SERVER_KEY}" \
    -CAfile "${CERT_DIR}/${CA_CERT}" -chain -name "${HOSTNAME}" \
    -out "${CERT_DIR}/${KEYSTORE}" -password pass:"${SSL_PASSWORD}"
check_ok "Creación del keystore PKCS12"

echo -e "   🛡️  Creando truststore..."
if [ "$USE_DOCKER_KEYTOOL" -eq 1 ]; then
    docker run --rm --user 0 --entrypoint keytool -v "${CERT_DIR}:/certs" "$KAFKA_IMAGE" \
        -importcert -alias "${EMPRESA}-ca" -file "/certs/${CA_CERT}" \
        -keystore "/certs/${TRUSTSTORE}" -storetype PKCS12 \
        -storepass "${SSL_PASSWORD}" -noprompt
else
    keytool -importcert -alias "${EMPRESA}-ca" -file "${CERT_DIR}/${CA_CERT}" \
        -keystore "${CERT_DIR}/${TRUSTSTORE}" -storetype PKCS12 \
        -storepass "${SSL_PASSWORD}" -noprompt
fi
check_ok "Creación del truststore"

echo "${SSL_PASSWORD}" > "${CERT_DIR}/keystore_creds"
echo "${SSL_PASSWORD}" > "${CERT_DIR}/truststore_creds"
echo "${SSL_PASSWORD}" > "${CERT_DIR}/key_creds"

echo -e "   🔍 Verificando certificados..."
if openssl verify -CAfile "${CERT_DIR}/${CA_CERT}" "${CERT_DIR}/${SERVER_CERT}" | grep -q "OK"; then
    echo -e "   ${GREEN}✅ Certificados verificados correctamente${NC}"
else
    echo -e "   ${RED}❌ Error en la verificación de certificados${NC}"; exit 1
fi

echo -e "   📋 SAN efectivo del certificado emitido:"
openssl x509 -in "${CERT_DIR}/${SERVER_CERT}" -noout -text \
    | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^/      /'

# El .cnf se CONSERVA para poder regenerar el cert sin rehacerlo a mano
mv "${CERT_DIR}/server-ext.cnf" "${BASE_DIR}/server-ext.cnf"
rm -f "${CERT_DIR}/${EMPRESA}-server.csr" "${CERT_DIR}"/*.srl 2>/dev/null
echo -e "   ${GREEN}✅ Certificados generados${NC}"
echo -e "   ${YELLOW}ℹ️  SAN guardado en ${BASE_DIR}/server-ext.cnf (para regenerar)${NC}"

# ── Script para regenerar el certificado ─────────────────────
cat > "${BASE_DIR}/regenerar-cert.sh" << REGEOF
#!/bin/bash
# Regenera el certificado del servidor reusando la CA existente.
# Edita server-ext.cnf para agregar IPs o DNS, luego ejecuta este script
# y reinicia el contenedor: docker compose restart
set -e
CERT_DIR="${CERT_DIR}"
BASE_DIR="${BASE_DIR}"
SSL_PASSWORD="${SSL_PASSWORD}"
DIAS=${SRV_DAYS}

# No emitir un certificado que dure más que la CA
CA_FIN=\$(date -d "\$(openssl x509 -in "\${CERT_DIR}/${CA_CERT}" -noout -enddate | cut -d= -f2)" +%s)
MAX=\$(( (CA_FIN - \$(date +%s)) / 86400 ))
if [ "\$MAX" -le 0 ]; then
    echo "❌ La CA ya venció. Hay que reinstalar (nueva CA y nuevo truststore en los clientes)."; exit 1
fi
[ "\$DIAS" -gt "\$MAX" ] && DIAS=\$MAX && echo "⚠️  Vigencia recortada a \$DIAS días para no superar a la CA."

openssl req -new -key "\${CERT_DIR}/${SERVER_KEY}" \\
    -out "\${CERT_DIR}/tmp-server.csr" \\
    -subj "/CN=${HOSTNAME}/O=${EMPRESA}/C=US"

openssl x509 -req \\
    -CA "\${CERT_DIR}/${CA_CERT}" -CAkey "\${CERT_DIR}/${CA_KEY}" \\
    -in "\${CERT_DIR}/tmp-server.csr" -out "\${CERT_DIR}/${SERVER_CERT}" \\
    -days \${DIAS} -CAcreateserial -passin pass:"\${SSL_PASSWORD}" \\
    -extfile "\${BASE_DIR}/server-ext.cnf" -extensions v3_req

rm -f "\${CERT_DIR}/${KEYSTORE}"
openssl pkcs12 -export \\
    -in "\${CERT_DIR}/${SERVER_CERT}" -inkey "\${CERT_DIR}/${SERVER_KEY}" \\
    -CAfile "\${CERT_DIR}/${CA_CERT}" -chain -name "${HOSTNAME}" \\
    -out "\${CERT_DIR}/${KEYSTORE}" -password pass:"\${SSL_PASSWORD}"

rm -f "\${CERT_DIR}/tmp-server.csr" "\${CERT_DIR}"/*.srl 2>/dev/null
chmod 644 "\${CERT_DIR}"/*.pem "\${CERT_DIR}/${TRUSTSTORE}" 2>/dev/null || true
chmod 600 "\${CERT_DIR}"/*-key.pem "\${CERT_DIR}"/*_creds "\${CERT_DIR}/${KEYSTORE}" 2>/dev/null || true
chown 1000:1000 "\${CERT_DIR}"/* 2>/dev/null || true

echo "✅ Certificado regenerado. SAN actual:"
openssl x509 -in "\${CERT_DIR}/${SERVER_CERT}" -noout -text | grep -A1 "Subject Alternative Name" | tail -1
echo ""
echo "⚠️  Reinicia Kafka:  docker compose restart"
echo "⚠️  La CA NO cambió: los clientes no necesitan un truststore nuevo."
REGEOF
chmod 700 "${BASE_DIR}/regenerar-cert.sh"   # contiene la contraseña SSL

# ── revisar-cert.sh: avisa cuánto falta para que venzan ─────
cat > "${BASE_DIR}/revisar-cert.sh" << REVEOF
#!/bin/bash
# Uso: ./revisar-cert.sh [días_de_aviso]   (por defecto 90)
# Código de salida: 0 = OK, 1 = por vencer, 2 = vencido
AVISO=\${1:-90}
CERT_DIR="${CERT_DIR}"
ESTADO=0
for c in "${CA_CERT}:CA" "${SERVER_CERT}:Servidor"; do
    f="\${CERT_DIR}/\${c%%:*}"; n="\${c##*:}"
    fin=\$(openssl x509 -in "\$f" -noout -enddate | cut -d= -f2)
    dias=\$(( (\$(date -d "\$fin" +%s) - \$(date +%s)) / 86400 ))
    fecha=\$(date -d "\$fin" +%Y-%m-%d)
    if [ "\$dias" -lt 0 ]; then
        echo "❌ [\$n] VENCIDO desde \$fecha"; ESTADO=2
    elif [ "\$dias" -le "\$AVISO" ]; then
        echo "⚠️  [\$n] vence el \$fecha (faltan \$dias días)"; [ \$ESTADO -lt 1 ] && ESTADO=1
    else
        echo "✅ [\$n] vence el \$fecha (faltan \$dias días)"
    fi
done
[ \$ESTADO -eq 1 ] && echo "   Renueva el servidor con ./regenerar-cert.sh (la CA requiere reinstalar)."
exit \$ESTADO
REVEOF
chmod 755 "${BASE_DIR}/revisar-cert.sh"

# ── Aviso automático diario (cron + syslog + archivo MOTD) ──
read -p "¿Instalar revisión diaria de vencimiento (cron, avisa 90 días antes)? (S/n): " INST_CRON
INST_CRON=${INST_CRON:-S}
if [[ "$INST_CRON" =~ ^[Ss] ]]; then
    CRON_LINE="0 8 * * * ${BASE_DIR}/revisar-cert.sh 90 > /tmp/kafka-${EMPRESA}-cert.txt 2>&1 || logger -t kafka-${EMPRESA}-cert -f /tmp/kafka-${EMPRESA}-cert.txt"
    ( crontab -l 2>/dev/null | grep -v "revisar-cert.sh"; echo "$CRON_LINE" ) | crontab -
    if [ -w /etc/profile.d ]; then
        cat > /etc/profile.d/kafka-${EMPRESA}-cert.sh << PROFEOF
# Muestra el aviso de vencimiento de Kafka al iniciar sesión (solo si hay problema)
${BASE_DIR}/revisar-cert.sh 90 >/tmp/.kafka-${EMPRESA}-cert 2>&1 || cat /tmp/.kafka-${EMPRESA}-cert
PROFEOF
        echo -e "   ${GREEN}✅ Aviso al iniciar sesión instalado en /etc/profile.d${NC}"
    fi
    echo -e "   ${GREEN}✅ Cron diario instalado (avisos en syslog: journalctl -t kafka-${EMPRESA}-cert)${NC}"
fi

# ── kafka_server_jaas.conf ───────────────────────────────────
echo -e "${GREEN}👤 Generando kafka_server_jaas.conf...${NC}"
cat > "${BASE_DIR}/kafka_server_jaas.conf" << EOF
KafkaServer {
  org.apache.kafka.common.security.plain.PlainLoginModule required
  username="${SASL_USER}"
  password="${SASL_PASSWORD}"
  user_${SASL_USER}="${SASL_PASSWORD}";
};
EOF
chown 1000:1000 "${BASE_DIR}/kafka_server_jaas.conf" 2>/dev/null || true
echo -e "   ${GREEN}✅ kafka_server_jaas.conf generado${NC}"

# ── docker-compose.yml ───────────────────────────────────────
echo -e "${GREEN}🐳 Generando docker-compose.yml...${NC}"
cat > "${BASE_DIR}/docker-compose.yml" << EOF
name: 'kafka-${EMPRESA}'
services:
  kafka:
    image: ${KAFKA_IMAGE}
    hostname: ${HOSTNAME}
    container_name: kafka-${EMPRESA}
    restart: always
    ports:
      # Solo se publica SASL_SSL. PLAINTEXT (9092) y CONTROLLER (9093) quedan
      # accesibles únicamente dentro del contenedor.
      - "9094:9094"
    environment:
      KAFKA_KRAFT_MODE: "true"
      KAFKA_PROCESS_ROLES: controller,broker
      KAFKA_NODE_ID: 1
      KAFKA_CONTROLLER_QUORUM_VOTERS: "1@kafka:9093"
      CLUSTER_ID: "${CLUSTER_ID}"
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,SASL_SSL://0.0.0.0:9094
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092,SASL_SSL://${ADVERTISED_HOST}:9094
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT,SASL_SSL:SASL_SSL
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_SSL_KEYSTORE_FILENAME: ${KEYSTORE}
      KAFKA_SSL_KEYSTORE_CREDENTIALS: keystore_creds
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_KEY_CREDENTIALS: key_creds
      KAFKA_SSL_TRUSTSTORE_FILENAME: ${TRUSTSTORE}
      KAFKA_SSL_TRUSTSTORE_CREDENTIALS: truststore_creds
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_CLIENT_AUTH: none
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL: PLAIN
      KAFKA_OPTS: "-Djava.security.auth.login.config=/etc/kafka/secrets/kafka_server_jaas.conf"
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_LOG_RETENTION_HOURS: 48
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_LOG_MESSAGE_TIMESTAMP_TYPE: "LogAppendTime"
      KAFKA_LOG4J_ROOT_LOGLEVEL: WARN
      KAFKA_LOG4J_LOGGERS: "kafka=WARN,kafka.controller=WARN,kafka.log.LogCleaner=WARN,state.change.logger=WARN,kafka.producer.async.DefaultEventHandler=WARN,org.apache.kafka=WARN"
      KAFKA_TOOLS_LOG4J_LOGLEVEL: ERROR
    volumes:
      - ./data:/var/lib/kafka/data
      - ./certs:/etc/kafka/secrets
      - ./kafka_server_jaas.conf:/etc/kafka/secrets/kafka_server_jaas.conf:ro
EOF
echo -e "   ${GREEN}✅ docker-compose.yml generado${NC}"

# ── client.properties ────────────────────────────────────────
echo -e "${GREEN}📄 Generando client.properties...${NC}"
cat > "${BASE_DIR}/client.properties" << EOF
security.protocol=SASL_SSL
bootstrap.servers=${SERVER_IP}:9094
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="${SASL_USER}" \
  password="${SASL_PASSWORD}";
ssl.truststore.location=/etc/kafka/secrets/${TRUSTSTORE}
ssl.truststore.password=${SSL_PASSWORD}
ssl.truststore.type=PKCS12
ssl.endpoint.identification.algorithm=
EOF
echo -e "   ${GREEN}✅ client.properties generado${NC}"

# ── client-verificado.properties (con validación activa) ─────
cat > "${BASE_DIR}/client-verificado.properties" << EOF
# Igual que client.properties pero CON verificación de hostname.
# Úsalo para comprobar que el SAN del certificado es correcto.
security.protocol=SASL_SSL
bootstrap.servers=${SERVER_IP}:9094
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="${SASL_USER}" \
  password="${SASL_PASSWORD}";
ssl.truststore.location=/etc/kafka/secrets/${TRUSTSTORE}
ssl.truststore.password=${SSL_PASSWORD}
ssl.truststore.type=PKCS12
ssl.endpoint.identification.algorithm=https
EOF

# ── Permisos ─────────────────────────────────────────────────
echo -e "${GREEN}🔧 Ajustando permisos...${NC}"
chown -R 1000:1000 "${DATA_DIR}" "${CERT_DIR}" 2>/dev/null || true
chmod 644 "${CERT_DIR}"/*.pem "${CERT_DIR}/${TRUSTSTORE}" 2>/dev/null || true
chmod 600 "${CERT_DIR}"/*-key.pem "${CERT_DIR}"/*_creds "${CERT_DIR}/${KEYSTORE}" 2>/dev/null || true
# El contenedor corre como uid 1000: si no pudimos hacer chown, dejamos lectura
# general para que Kafka arranque (ejecuta el script con sudo para evitarlo).
if [ "$(stat -c %u "${CERT_DIR}/${KEYSTORE}")" != "1000" ]; then
    echo -e "   ${YELLOW}⚠️  No se pudo asignar uid 1000; claves quedan en 644. Usa sudo para restringirlas.${NC}"
    chmod 644 "${CERT_DIR}"/* 2>/dev/null || true
fi

# ── comandos-rapidos.sh ──────────────────────────────────────
cat > "${BASE_DIR}/comandos-rapidos.sh" << CMDFILE
#!/bin/bash
EMPRESA="${EMPRESA}"
SASL_USER="${SASL_USER}"
SASL_PASSWORD="${SASL_PASSWORD}"
SSL_PASSWORD="${SSL_PASSWORD}"
TRUSTSTORE="${TRUSTSTORE}"
SERVER_CERT="${SERVER_CERT}"

crear_client() {
    docker exec -it kafka-\${EMPRESA} bash -c "cat > /tmp/client.properties << PROPS
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"\${SASL_USER}\" password=\"\${SASL_PASSWORD}\";
ssl.truststore.location=/etc/kafka/secrets/\${TRUSTSTORE}
ssl.truststore.password=\${SSL_PASSWORD}
ssl.truststore.type=PKCS12
ssl.endpoint.identification.algorithm=
PROPS"
    echo "✅ client.properties creado en /tmp/client.properties"
}
listar_topics() {
    docker exec -it kafka-\${EMPRESA} kafka-topics --list \\
        --bootstrap-server localhost:9094 --command-config /tmp/client.properties
}
crear_topic() {
    [ -z "\$1" ] && echo "Uso: crear_topic <nombre_topic>" && return 1
    docker exec -it kafka-\${EMPRESA} kafka-topics --create \\
        --topic "\$1" --bootstrap-server localhost:9094 \\
        --command-config /tmp/client.properties --partitions 1 --replication-factor 1
}
producir() {
    [ -z "\$1" ] && echo "Uso: producir <nombre_topic>" && return 1
    docker exec -it kafka-\${EMPRESA} kafka-console-producer \\
        --topic "\$1" --bootstrap-server localhost:9094 --producer.config /tmp/client.properties
}
consumir() {
    [ -z "\$1" ] && echo "Uso: consumir <nombre_topic>" && return 1
    docker exec -it kafka-\${EMPRESA} kafka-console-consumer \\
        --topic "\$1" --bootstrap-server localhost:9094 \\
        --consumer.config /tmp/client.properties --from-beginning
}
ver_san() {
    openssl x509 -in ./certs/\${SERVER_CERT} -noout -text | grep -A1 "Subject Alternative Name"
}
probar_tls() {
    [ -z "\$1" ] && echo "Uso: probar_tls <ip_o_host>" && return 1
    openssl s_client -connect "\$1:9094" -servername "\$1" </dev/null 2>/dev/null \\
        | openssl x509 -noout -subject -ext subjectAltName
}
ver_vencimiento() { ${BASE_DIR}/revisar-cert.sh "\${1:-90}"; }
ver_logs() { docker logs -f kafka-\${EMPRESA}; }
estado()   { docker ps | grep kafka-\${EMPRESA}; }

echo "📋 Comandos: crear_client | listar_topics | crear_topic | producir | consumir"
echo "            ver_san | probar_tls <ip> | ver_vencimiento | ver_logs | estado"
CMDFILE

chmod 700 "${BASE_DIR}/comandos-rapidos.sh"   # contiene contraseñas
chmod 600 "${BASE_DIR}/client.properties" "${BASE_DIR}/client-verificado.properties"
if [ "$(stat -c %u "${BASE_DIR}/kafka_server_jaas.conf")" = "1000" ]; then chmod 600 "${BASE_DIR}/kafka_server_jaas.conf"; fi

# ── Resumen final ────────────────────────────────────────────
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}   ✅ INSTALACIÓN COMPLETADA — Archivos en: ${BASE_DIR}${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${YELLOW}🌐 El certificado cubre estas direcciones:${NC}"
for ip in $SAN_IP_LIST; do echo -e "   • ${GREEN}${ip}${NC}"; done
for d in $SAN_DNS_LIST; do echo -e "   • ${GREEN}${d}${NC}"; done
echo ""
echo -e "${YELLOW}🚀 Siguientes pasos:${NC}"
echo -e "   1. ${GREEN}docker compose up -d${NC}"
echo -e "   2. ${GREEN}docker logs kafka-${EMPRESA} 2>&1 | tail -20${NC}"
echo -e "   3. ${GREEN}source comandos-rapidos.sh && crear_client && listar_topics${NC}"
echo ""
echo -e "${YELLOW}📅 Vencimientos (anótalos):${NC}"
"${BASE_DIR}/revisar-cert.sh" 90 | sed 's/^/   /' || true
echo -e "   Revisar cuando quieras: ${GREEN}./revisar-cert.sh${NC}"
echo ""
echo -e "${YELLOW}🔧 Para agregar IPs después:${NC}"
echo -e "   Edita ${GREEN}server-ext.cnf${NC} y ejecuta ${GREEN}./regenerar-cert.sh${NC}"
echo ""
echo -e "${YELLOW}📣 Kafka anuncia: ${GREEN}${ADVERTISED_HOST}:9094${NC}"
if ! [[ $ADVERTISED_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
echo -e "   Cada cliente debe resolver ${GREEN}${ADVERTISED_HOST}${NC} a la IP por la que llega:"
echo -e "   • Mismo segmento:  ${GREEN}echo \"${SERVER_IP}  ${ADVERTISED_HOST}\" | sudo tee -a /etc/hosts${NC}"
echo -e "   • Detrás de NAT:   ${GREEN}echo \"<IP_NAT>  ${ADVERTISED_HOST}\" | sudo tee -a /etc/hosts${NC}"
echo -e "   • Elastic Agent en Docker:  ${GREEN}extra_hosts: [\"${ADVERTISED_HOST}:${SERVER_IP}\"]${NC}"
fi
echo ""
echo -e "${RED}⚠️  Firewall: sudo ufw allow 9094/tcp  (9092/9093 ya no se publican)${NC}"
echo -e "${BLUE}============================================================${NC}"

# ── Arranque y prueba automática ─────────────────────────────
echo ""
read -p "¿Levantar Kafka ahora y probar la conexión SASL_SSL? (S/n): " ARRANCAR
ARRANCAR=${ARRANCAR:-S}
if [[ "$ARRANCAR" =~ ^[Ss] ]]; then
    docker compose -f "${BASE_DIR}/docker-compose.yml" up -d
    echo -ne "   ⏳ Esperando a que Kafka responda"
    LISTO=0
    for i in $(seq 1 30); do
        if docker exec "kafka-${EMPRESA}" kafka-broker-api-versions --bootstrap-server localhost:9092 >/dev/null 2>&1; then
            LISTO=1; break
        fi
        echo -n "."; sleep 3
    done
    echo ""
    if [ "$LISTO" -eq 1 ]; then
        ok "Kafka responde en PLAINTEXT interno"
        docker exec "kafka-${EMPRESA}" bash -c "cat > /tmp/client.properties" < "${BASE_DIR}/client.properties"
        if docker exec "kafka-${EMPRESA}" kafka-topics --list --bootstrap-server localhost:9094 \
               --command-config /tmp/client.properties >/dev/null 2>&1; then
            ok "SASL_SSL (9094) funciona: TLS + usuario/contraseña correctos"
        else
            warn "Kafka arrancó pero falló la prueba SASL_SSL. Revisa: docker logs kafka-${EMPRESA}"
        fi
    else
        warn "Kafka no respondió en 90 s. Revisa: docker logs kafka-${EMPRESA} 2>&1 | tail -40"
        docker logs "kafka-${EMPRESA}" 2>&1 | grep -iE "cluster.id|INCONSISTENT" >/dev/null && \
            warn "Parece un CLUSTER_ID distinto al de ./data. Si los datos no importan: docker compose down && sudo rm -rf data/*"
    fi
    if [ "$CA_REUTILIZADA" -eq 0 ]; then
        echo ""
        warn "CA NUEVA: copia ${CERT_DIR}/${TRUSTSTORE} a Logstash y actualiza la CA en el output de Fleet."
    fi
fi

}

main "$@"; exit $?

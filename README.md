# kafka-installer

Instalador de **Apache Kafka (Confluent cp-kafka) en Docker con TLS + SASL**, modo KRaft, listo para recibir datos de Elastic Agent y entregarlos a Logstash.

## Instalación rápida

```bash
mkdir ~/kafka && cd ~/kafka
curl -fsSL https://raw.githubusercontent.com/cloudfactorybo/kafka-installer/main/get-kafka-installer.sh | bash
sudo ./install-kafka-seguro.sh
```

En un solo paso (descarga y ejecuta):

```bash
curl -fsSL https://raw.githubusercontent.com/cloudfactorybo/kafka-installer/main/get-kafka-installer.sh | bash -s -- --run
```

Versión concreta de Kafka:

```bash
sudo ./install-kafka-seguro.sh --version 7.9.0
```

## Requisitos

Linux (amd64 o arm64), Docker con el plugin `docker compose` v2 y `openssl`. Java no es necesario.

## Qué hace

El instalador verifica el sistema, detecta la última versión estable de `cp-kafka`, genera una CA propia y el certificado del servidor (con SAN dinámico: IPs locales, NAT y nombres DNS), crea `docker-compose.yml`, `kafka_server_jaas.conf` y `client.properties`, y deja scripts auxiliares para renovar el certificado y revisar su vencimiento. Solo se publica el puerto **9094 (SASL_SSL)**.

Si detecta una instalación previa, hace un respaldo y ofrece reutilizar la CA para que los clientes no necesiten un truststore nuevo.

## Clientes detrás de NAT

Kafka anuncia un nombre (por defecto el hostname del servidor). Cada cliente debe resolverlo a la IP por la que llega:

```bash
# Cliente detrás de NAT
echo "<IP_NAT>  <hostname-kafka>" | sudo tee -a /etc/hosts
```

En Elastic Agent sobre Docker:

```yaml
extra_hosts:
  - "<hostname-kafka>:<IP_interna>"
```

## Seguridad

Las contraseñas se piden durante la instalación y **no** se guardan en este repositorio. Los archivos generados (certificados, credenciales, compose) están en `.gitignore`; no los subas.

## Publicar una nueva versión

```bash
git tag v1.0.1
git push origin v1.0.1
```

GitHub Actions verifica la sintaxis, genera el `.sha256` y publica la release. `get-kafka-installer.sh` siempre descarga la última.

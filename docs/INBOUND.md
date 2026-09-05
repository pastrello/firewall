# Projeto inbound — "fora para dentro"

## Princípio

O modelo inbound deve partir de **negação por padrão**. Uma publicação só existe quando uma regra declara explicitamente:

- interface/WAN;
- protocolo;
- porta pública;
- destino interno;
- porta interna;
- origens permitidas;
- logging/rate limit desejados.

## Dois tipos de regra

### 1. `publish:` — DNAT para servidor interno

Exemplo conceitual:

```text
publish: name=portal proto=tcp wan=eth1 ext_port=443 dst=192.168.11.50 dst_port=443 src=any
publish: name=ssh-admin proto=tcp wan=eth1 ext_port=2222 dst=192.168.11.20 dst_port=22 src=@admins
```

Esse tipo gera duas partes inseparáveis:

- `nat/PREROUTING` para DNAT;
- `filter/FORWARD` autorizando somente o fluxo declarado.

### 2. `input:` — serviço no próprio firewall

Exemplo conceitual:

```text
input: name=wireguard proto=udp wan=eth1 port=51820 src=any
input: name=ssh-firewall proto=tcp wan=eth1 port=22 src=@admins
```

Esse tipo altera apenas a chain `INPUT`.

## Grupos de origem

Para não repetir centenas de redes em várias publicações:

```text
source-group: admins 203.0.113.10/32
source-group: fornecedores fornecedor.example.com
```

Na primeira implementação IPv4, os grupos podem usar `ipset hash:net`; FQDNs são resolvidos de modo semelhante ao outbound.

## Ordem proposta para FORWARD inbound

1. `ESTABLISHED,RELATED` -> ACCEPT;
2. `INVALID` -> DROP;
3. regras de publicação explicitamente autorizadas;
4. política outbound existente;
5. logging de novos drops;
6. DROP final.

## Recursos do MVP

- TCP e UDP;
- porta única e intervalo de portas;
- DNAT 1:1 de porta;
- allowlist de origem por IP/CIDR/FQDN;
- `any` somente quando explicitamente declarado;
- logging apenas de `NEW`;
- rate limit opcional;
- contador por regra;
- `generate` sem aplicar;
- validação de conflito de porta pública;
- backup/rollback usando a infraestrutura existente.

## Recursos seguintes

### Segurança

- `hashlimit` por origem para serviços sensíveis;
- `connlimit` opcional;
- blacklist temporária em ipset;
- integração opcional com fail2ban para serviços locais;
- proteção contra publicação acidental de portas administrativas;
- aviso quando `src=any` for usado em SSH/RDP/WinRM ou outras portas administrativas conhecidas.

### NAT

- múltiplos IPs públicos;
- múltiplas WANs;
- hairpin NAT/NAT reflection opcional;
- SNAT específico por publicação quando necessário;
- validação de sobreposição/conflito entre regras.

### Operação

- `list-published`;
- `enable-rule` / `disable-rule` sem editar o arquivo principal;
- estatísticas por publicação;
- exportação de counters;
- histórico de mudanças;
- modo `diff`, mostrando exatamente o que mudará antes de `apply`.

### Futuro

- IPv6;
- backend nftables nativo;
- conjuntos dinâmicos de threat intelligence;
- testes automatizados em network namespaces;
- GitHub Actions para parser/lint/testes sem tocar em firewall real.

## Ponto crítico: interfaces

O script legado aceita integralmente INPUT de várias interfaces. Para um modelo inbound seguro será obrigatório classificar interfaces em:

```text
WAN_INTERFACES="eth1"
LAN_INTERFACES="eth0 eno1"
VPN_INTERFACES="wg0"
```

Uma WAN nunca deve fazer parte de `INPUT_TRUSTED_INTERFACES`. Essa refatoração deve ocorrer antes de habilitar publicações inbound em produção.

# Firewall Unidades

Firewall Linux otimizado para ambientes com listas extensas de autorização, inicialmente voltado ao modelo **dentro → fora** e com arquitetura preparada para evoluir para **fora → dentro**.

Compatibilidade alvo da geração atual: CentOS/RHEL/Rocky Linux 7, 8 e 9, usando `iptables` + `ipset`.

## Por que este projeto existe

O gerador legado criava uma regra `iptables` para cada item da configuração. Em listas muito grandes isso resulta em dezenas de milhares de processos e uma aplicação lenta.

A v2 processa as listas antes da aplicação, remove duplicatas, resolve FQDNs, consolida CIDRs e usa `ipset` + `iptables-restore`.

No arquivo real que motivou o projeto, 72.359 entradas `d:` continham 40.271 IP/CIDR únicos e puderam ser consolidadas em aproximadamente 2.075 redes/hosts.

## Formato outbound atual

```text
d: 203.0.113.10
d: 10.20.0.0/16
d: api.example.com
s: 10.40.0.0/16
p: 443
m: 02:00:00:00:00:10
c: 02:00:00:00:00:20
```

- `d:` destino liberado;
- `s:` origem liberada;
- `p:` porta TCP global liberada;
- `m:` MAC liberado para TCP/443;
- `c:` MAC com FORWARD total.

Veja `examples/regras_firewall.conf.example`.

## v2.2 — hardening de interfaces

A v2.2 introduz papéis explícitos para as interfaces sem quebrar automaticamente instalações existentes.

```bash
INTERFACE_POLICY_MODE="compat"   # compat | roles
WAN_INTERFACES="eth1"
LAN_INTERFACES="eth0"
VPN_INTERFACES="wg0"
```

### `compat`

Preserva `INPUT_TRUSTED_INTERFACES` como nas versões anteriores. É o modo padrão para atualização segura, mas emite avisos quando uma interface classificada como WAN também está na lista legada de confiança.

### `roles`

É o modo recomendado depois da migração:

- somente LAN/VPN recebem ACCEPT genérico em INPUT;
- WAN nunca recebe ACCEPT genérico;
- uma WAN ainda presente em `INPUT_TRUSTED_INTERFACES` causa erro;
- sobreposição WAN/LAN/VPN causa erro;
- interfaces inexistentes podem gerar `ignore`, `warn` ou `error`;
- redes históricas de INPUT são restritas às interfaces LAN/VPN.

A migração detalhada está em `docs/V2.2-MIGRATION.md`.

## Serviços locais declarativos

As antigas regras fixas da porta 300 foram removidas do gerador e agora ficam em `LOCAL_INPUT_RULES`:

```bash
LOCAL_INPUT_RULES=(
    "name=admin-lan iface=@lan proto=tcp port=300 src=any"
    "name=admin-wan iface=@wan proto=tcp port=300 src=203.0.113.10/32"
)
```

Campos:

- `name=` identificador;
- `iface=` nome da interface ou `@wan`, `@lan`, `@vpn`;
- `proto=` `tcp` ou `udp`;
- `port=` porta única ou intervalo `inicio:fim`;
- `src=` `any` ou IPv4/CIDR;
- `enabled=` opcional, `1` por padrão.

No modo `roles`, uma regra local explícita na WAN com `src=any` é permitida, mas gera aviso para revisão. FQDN/grupos de origem serão tratados pelo módulo inbound.

## Instalação

```bash
mkdir -p /operacao/firewall.unidades
cp firewall_unidades.sh /operacao/firewall.unidades/
cp -r lib /operacao/firewall.unidades/
cp firewall_unidades.conf.example /operacao/firewall.unidades/firewall_unidades_v2.conf
chmod 700 /operacao/firewall.unidades/firewall_unidades.sh
chmod 600 /operacao/firewall.unidades/firewall_unidades_v2.conf
```

Dependências de aplicação:

```text
iptables
iptables-save
iptables-restore
ipset
getent
timeout
flock
awk
sort
```

Python 3 é opcional, porém recomendado para consolidação CIDR.

## Fluxo seguro de atualização para v2.2

Primeiro permaneça em `compat`:

```bash
./firewall_unidades.sh diagnose
./firewall_unidades.sh check --resolve
./firewall_unidades.sh generate 192.168.11.1
```

Revise especialmente o bloco `INPUT` gerado. Depois classifique as interfaces, troque para:

```bash
INTERFACE_POLICY_MODE="roles"
```

e repita `diagnose`, `check` e `generate`. Somente depois:

```bash
./firewall_unidades.sh apply 192.168.11.1
```

Atualização somente dos grandes conjuntos:

```bash
./firewall_unidades.sh refresh-sets
```

Rollback:

```bash
./firewall_unidades.sh backups
./firewall_unidades.sh rollback
```

## `diagnose`

A v2.2 mostra, sem alterar o firewall:

- distribuição WAN/LAN/VPN;
- interfaces presentes/ausentes;
- conjunto efetivo de interfaces confiáveis em INPUT;
- `net.ipv4.ip_forward`;
- `rp_filter` global e por interface classificada;
- aviso específico para `rp_filter=1` em cenários multi-WAN;
- validação das regras locais declarativas.

## Segurança operacional

O arquivo de regras real normalmente contém IPs, nomes internos, MACs e informações de infraestrutura. Por isso, `regras_firewall.conf`, arquivos locais de parâmetros, backups, caches e logs estão no `.gitignore` e não devem ser publicados no repositório.

O projeto assume controle das tabelas IPv4 `filter` e `nat`. Por padrão aborta se `firewalld` estiver ativo.

## Próxima etapa: inbound

O desenho do modelo **fora → dentro** está em `docs/INBOUND.md`. Ele separa:

- publicação de serviços internos (`DNAT + FORWARD`);
- serviços locais do próprio firewall (`INPUT`);
- grupos de origem/allowlists;
- rate limit, logging, validação de conflitos e rollback.

A v2.2 conclui o pré-requisito mais importante para esse módulo: interfaces WAN, LAN e VPN passam a ter papéis verificáveis e a WAN deixa de poder herdar confiança genérica no modo `roles`.

## Documentação

- `docs/ARCHITECTURE.md`
- `docs/V2.2-MIGRATION.md`
- `docs/INBOUND.md`
- `CHANGELOG.md`

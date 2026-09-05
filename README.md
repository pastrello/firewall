# Firewall Unidades

Firewall Linux otimizado para ambientes com listas extensas de autorização, inicialmente voltado ao modelo **dentro → fora** e com arquitetura preparada para evoluir para **fora → dentro**.

Compatibilidade alvo da geração atual: CentOS/RHEL/Rocky Linux 7, 8 e 9, usando `iptables` + `ipset`.

## Por que este projeto existe

O gerador legado criava uma regra `iptables` para cada item da configuração. Em listas muito grandes isso resulta em dezenas de milhares de processos e uma aplicação lenta.

A v2 processa as listas antes da aplicação, remove duplicatas, resolve FQDNs, consolida CIDRs e usa `ipset` + `iptables-restore`.

No arquivo real que motivou o projeto, 72.359 entradas `d:` continham 40.271 IP/CIDR únicos e puderam ser consolidadas em aproximadamente 2.075 redes/hosts.

## Formato atual

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

## Instalação

```bash
mkdir -p /operacao/firewall.unidades
cp firewall_unidades.sh /operacao/firewall.unidades/
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

## Fluxo seguro

```bash
./firewall_unidades.sh stats
./firewall_unidades.sh check --resolve
./firewall_unidades.sh generate 192.168.11.1
./firewall_unidades.sh diagnose
```

Somente depois da revisão:

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

## Mudanças da v2.1

- `FORWARD` stateful com `ESTABLISHED,RELATED`;
- `INVALID` descartado cedo;
- DROP final explícito;
- compatibilidade de `192.168.0.0/16` representada por uma regra clara;
- WireGuard corrigido de `--sport` para `--dport`;
- logging exclui `172.16.0.0/12`, não `172.0.0.0/8`;
- logging limitado por padrão e opcionalmente somente para novas conexões;
- interfaces confiáveis de INPUT configuráveis;
- comando `diagnose`.

## Segurança operacional

O arquivo de regras real normalmente contém IPs, nomes internos, MACs e informações de infraestrutura. Por isso, `regras_firewall.conf`, arquivos locais de parâmetros, backups, caches e logs estão no `.gitignore` e não devem ser publicados no repositório.

O projeto assume controle das tabelas IPv4 `filter` e `nat`. Por padrão aborta se `firewalld` estiver ativo.

## Próxima etapa: inbound

O desenho do modelo **fora → dentro** está em `docs/INBOUND.md`. Ele separa:

- publicação de serviços internos (`DNAT + FORWARD`);
- serviços locais do próprio firewall (`INPUT`);
- grupos de origem/allowlists;
- rate limit, logging, validação de conflitos e rollback.

Antes de colocar inbound em produção, a prioridade é classificar explicitamente interfaces como WAN/LAN/VPN e impedir que uma WAN seja tratada como interface totalmente confiável.

## Documentação

- `docs/ARCHITECTURE.md`
- `docs/INBOUND.md`
- `CHANGELOG.md`

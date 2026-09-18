# Changelog

## 2.3.1 - 2026-09-18

### Correção

- corrige falha `outfile: variável não associada` em `dynamic_query_host()` quando executado com `set -u`;
- endurece `prepare_dynamic_snapshot()` contra o mesmo padrão de associação em declaração `local`;
- adiciona teste de regressão que executa a implementação real do resolver dinâmico sob `set -u`.

## 2.3.0 - 2026-09-17

### Dynamic DNS outbound

- adiciona `u:` para destinos FQDN cujo IPv4 pode mudar durante o dia;
- adiciona `FWU_DYN_DST_V4` e uma única regra FORWARD para o conjunto;
- `apply` e `refresh-sets` inicializam/atualizam também `u:`;
- backup/rollback incluem o set dinâmico e seu estado persistente.

### DNS watcher

- daemon TTL-aware executado pelo próprio `firewall_unidades.sh`;
- intervalo TTL/divisor com limites mínimo/máximo;
- suporta múltiplos registros A;
- mudança de IP usa `DYNAMIC_DNS_GRACE`;
- falhas DNS preservam último estado válido;
- `DYNAMIC_DNS_FAIL_POLICY=keep|drop` controla expiração após `STALE_MAX`;
- `ipset swap` ocorre somente quando o conteúdo efetivamente muda;
- watcher compartilha o lock de `apply`/`rollback`.

### systemd / operação

- `installservice` cria, habilita e inicia `firewall-dnswatch.service`;
- `uninstallservice` remove o serviço preservando set/estado;
- `dynamic-refresh` força atualização imediata;
- `dynamic-status` mostra serviço, último ciclo, TTL, falhas e IPs;
- `diagnose` informa disponibilidade do `dig` e estado do watcher.

### Validação

- `tests/test_v23_dynamic.sh` cobre parser `u:`, limites TTL, troca de IP, grace e cache em falha DNS;
- testes locais passaram; o start real do unit systemd deve ser validado em um host Rocky/CentOS com systemd, iptables e ipset.

## 2.2.0 - 2026-09-05

- hardening pré-inbound com `INTERFACE_POLICY_MODE=compat|roles`;
- papéis `WAN_INTERFACES`, `LAN_INTERFACES` e `VPN_INTERFACES`;
- WAN sem ACCEPT genérico em `roles`;
- `LOCAL_INPUT_RULES` declarativo;
- diagnóstico de papéis, `ip_forward` e `rp_filter`.

## 2.1.0 - 2026-09-05

- `FORWARD` stateful com `ESTABLISHED,RELATED` e descarte de `INVALID`;
- DROP final explícito;
- WireGuard corrigido para `--dport`;
- logging corrigido/limitado e comando `diagnose`.

## 2.0.0

- substitui milhares de chamadas `iptables` por `ipset` + `iptables-restore`;
- resolução paralela de FQDN com cache;
- deduplicação/consolidação CIDR;
- backup, rollback, lock e geração atômica.

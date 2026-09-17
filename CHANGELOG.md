# Changelog

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

### Testes

- `tests/test_v23_dynamic.sh` cobre parser `u:`, limites TTL, troca de IP, grace e cache em falha DNS.

## 2.2.0 - 2026-09-05

### Hardening pré-inbound

- adiciona `INTERFACE_POLICY_MODE=compat|roles`;
- adiciona `WAN_INTERFACES`, `LAN_INTERFACES` e `VPN_INTERFACES`;
- em `roles`, WAN nunca recebe ACCEPT genérico em `INPUT`;
- detecta sobreposição entre papéis e impede WAN em `INPUT_TRUSTED_INTERFACES`;
- adiciona política de interfaces ausentes `ignore|warn|error`;
- `INPUT_TRUSTED_SOURCES` é limitado a LAN/VPN no modo `roles`;
- adiciona descarte de `INVALID` em `INPUT`;
- move porta TCP/300 para `LOCAL_INPUT_RULES` declarativo;
- adiciona diagnóstico de papéis, `ip_forward` e `rp_filter`.

## 2.1.0 - 2026-09-05

- adiciona `ESTABLISHED,RELATED` ao `FORWARD` e descarta `INVALID`;
- usa DROP final explícito;
- corrige WireGuard para `--dport`;
- corrige exclusão de logging para `172.16.0.0/12`;
- adiciona rate-limit de logs e `diagnose`.

## 2.0.0

- substitui milhares de chamadas `iptables` por `ipset` + `iptables-restore`;
- resolução paralela de FQDN com cache;
- deduplicação/consolidação CIDR;
- backup, rollback, lock e geração atômica;
- corrige posição do REJECT na chain INPUT.

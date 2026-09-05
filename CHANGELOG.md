# Changelog

## 2.2.0 - 2026-09-05

### Hardening pré-inbound

- adiciona `INTERFACE_POLICY_MODE=compat|roles`;
- adiciona classificação explícita `WAN_INTERFACES`, `LAN_INTERFACES` e `VPN_INTERFACES`;
- em `roles`, WAN nunca recebe ACCEPT genérico em `INPUT`;
- detecta sobreposição entre papéis WAN/LAN/VPN;
- impede WAN de permanecer em `INPUT_TRUSTED_INTERFACES` no modo `roles`;
- adiciona política configurável para interfaces ausentes: `ignore`, `warn` ou `error`;
- redes históricas `INPUT_TRUSTED_SOURCES` deixam de ser globais no modo `roles` e são limitadas a LAN/VPN;
- adiciona descarte de `INVALID` também na chain `INPUT`.

### Serviços locais

- remove do gerador as regras fixas da porta TCP/300;
- adiciona `LOCAL_INPUT_RULES` declarativo;
- suporta TCP/UDP, porta única/faixa, origem IPv4/CIDR/any e enable/disable;
- suporta seletores `@wan`, `@lan` e `@vpn`;
- alerta quando uma regra explícita publica serviço local na WAN para `src=any`.

### Diagnóstico

- `diagnose` mostra papéis e presença das interfaces;
- mostra `rp_filter` por interface classificada;
- avisa se `ip_forward` não está ativo;
- avisa sobre `rp_filter=1` em WANs quando há múltiplas WANs;
- `check` valida também política de interfaces e regras locais.

### Compatibilidade

- `compat` é o modo padrão para não alterar silenciosamente instalações v2.1;
- o formato outbound `d:`, `s:`, `p:`, `m:`, `c:` permanece inalterado;
- as oito regras históricas da porta 300 continuam como defaults declarativos até serem sobrescritas pela configuração local.

## 2.1.0 - 2026-09-05

### Segurança e clareza de política

- adiciona `ESTABLISHED,RELATED` à chain `FORWARD`;
- descarta `INVALID` cedo no `FORWARD`;
- troca o DROP condicional legado por uma regra explícita para `192.168.0.0/16` seguida de DROP final;
- corrige as exceções WireGuard para usar `--dport` em vez de `--sport`;
- corrige exclusão de logging de `172.0.0.0/8` para o bloco privado `172.16.0.0/12`;
- logging passa a ser limitado por padrão e pode registrar apenas conexões novas;
- interfaces confiáveis de INPUT passam a ser configuráveis;
- novo comando somente leitura `diagnose`.

### Compatibilidade

- mantém o formato existente de `regras_firewall.conf` (`d:`, `s:`, `p:`, `m:`, `c:`);
- mantém compatibilidade alvo com EL7/EL8/EL9;
- continua usando iptables + ipset nesta geração.

## 2.0.0

- substitui milhares de chamadas individuais a `iptables` por `ipset` e `iptables-restore`;
- resolução paralela de FQDN com cache;
- deduplicação e consolidação CIDR;
- backup, rollback, lock e geração atômica;
- correção da posição do REJECT na chain INPUT.

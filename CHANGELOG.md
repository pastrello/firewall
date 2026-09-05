# Changelog

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

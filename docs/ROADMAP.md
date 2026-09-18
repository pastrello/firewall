# Roadmap e pendências

## Estado atual — v2.4

- parser e política comuns;
- hardening WAN/LAN/VPN;
- DNS dinâmico `u:`;
- backend `iptables + ipset` atrás de API interna;
- backup/rollback backend-aware;
- testes de regressão e GitHub Actions.

## v2.5 — nftables: geração e inspeção

- implementar `lib/backend/nftables.sh`;
- sets nativos para `d:`, `u:` e `s:`;
- `generate`, validação e `backend-info`;
- comparação semântica com o backend iptables;
- ainda sem migração automática.

## v2.6 — nftables operacional

- `apply`, backup e rollback;
- watcher `u:` atualizando set nftables;
- status/diagnose completos;
- testes de equivalência e recuperação;
- documentação de migração controlada.

## Inbound

A issue #1 continua aberta. O parser `publish:`, `input:` e `source-group:` será retomado sobre a camada de backend para evitar implementar a mesma função duas vezes.

## Pendências técnicas preservadas deliberadamente

Estas regras já existiam e não foram alteradas na v2.4 para evitar mudança silenciosa em produção:

- redes `172.16.0.0/16` e `10.80.0.0/16` codificadas no FORWARD;
- exceção NAT `192.168.0.0/16 -> 10.80.0.0/24`;
- MASQUERADE calculado a partir de uma rede `/24` do `SERVER_IP`;
- exceção `ALLOW_RFC1918_192_DST`;
- regras WireGuard históricas;
- IPv4 apenas.

Esses pontos devem migrar para configuração declarativa antes de uma futura versão principal.

## Princípios

- nunca executar iptables e nftables como backends simultâneos do projeto;
- não escolher backend automaticamente;
- não usar `flush ruleset` no futuro backend nftables;
- o backend nftables deverá controlar apenas tabela(s) próprias do Firewall Unidades.

# Arquitetura

## Objetivo

O projeto controla um firewall Linux que atua como roteador entre redes internas e externas. A política é independente do mecanismo de firewall; a v2.4 conclui a primeira separação entre lógica comum e backend.

## Pipeline

1. `regras_firewall.conf` é lido e validado;
2. regras `d:`, `u:` e `s:` são deduplicadas;
3. FQDNs `d:`/`s:` são resolvidos com cache;
4. redes são consolidadas quando Python 3 está disponível;
5. o watcher mantém o estado de `u:`;
6. a camada comum entrega a política ao backend selecionado;
7. o backend gera, valida e aplica seu artefato;
8. backup/rollback e conjuntos também passam pela API do backend.

## Camadas

~~~text
regras_firewall.conf
        |
        v
 parser / DNS / interfaces / dynamic DNS
        |
        v
  API comum de backend
        |
        +--> iptables + ipset   [v2.4]
        |
        +--> nftables           [v2.5+]
~~~

## API de backend v2.4

A implementação concreta deve fornecer, entre outras:

- `backend_generate_rules`;
- `backend_validate_rules`;
- `backend_apply_rules`;
- `backend_backup_rules` / `backend_restore_rules`;
- `backend_set_ensure`;
- `backend_set_load_atomic`;
- `backend_set_export_entries`;
- `backend_set_destroy`;
- `backend_set_count`;
- `backend_ruleset_uses_set`.

O dispatcher está em `lib/backend/00_backend.sh`. O backend atual está em `lib/backend/iptables.sh`.

## Seleção

~~~bash
BACKEND="iptables"
~~~

A v2.4 não possui modo `auto`. `BACKEND=nftables` é rejeitado deliberadamente até a implementação da v2.5.

## Conjuntos lógicos

Os nomes lógicos permanecem:

- `FWU_DST_V4`: destinos `d:`;
- `FWU_DYN_DST_V4`: destinos `u:`;
- `FWU_SRC_V4`: origens.

No backend iptables eles são `ipset`. Um backend nftables poderá implementá-los como sets nativos sem alterar o parser ou o watcher.

## Backup e rollback

Backups novos registram o backend em `backup/backend`. Backups 2.0–2.3 sem metadata, mas contendo `iptables.save`, são reconhecidos como `iptables`.

Um rollback só é permitido quando o backend do backup é compatível com o backend configurado.

## DNS dinâmico

`d: hostname` é snapshot atualizado por `apply`/`refresh-sets`.

`u: hostname` é dependência contínua. O daemon usa a API de conjuntos do backend e não conhece mais `ipset` diretamente.

## Papéis de interface

A v2.2 separa WAN/LAN/VPN e impede confiança genérica de WAN no modo `roles`.

## Política

1. **outbound-static** — `d:` e regras tradicionais;
2. **outbound-dynamic** — `u:`;
3. **inbound-forward** — planejado;
4. **inbound-local** — planejado.

## Compatibilidade

Na v2.4 o backend `iptables` preserva a semântica da v2.3.1. Nenhuma conversão automática para nftables é feita.

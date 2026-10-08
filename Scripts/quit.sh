#!/usr/bin/env bash
# Fecha o Rosen e espera ele sair de fato: ao receber SIGTERM ele encerra os túneis antes,
# e um `open` logo em seguida reativaria a instância que ainda está fechando.
pkill -x Rosen 2>/dev/null || exit 0
for _ in $(seq 1 50); do
  pgrep -x Rosen >/dev/null || exit 0
  sleep 0.1
done
pkill -9 -x Rosen 2>/dev/null || true

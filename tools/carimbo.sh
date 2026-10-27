#!/bin/bash
# Carimba cada linha com a hora em que chegou, no formato do log do dispatcher
# (AAAA-MM-DD HH:MM:SS). Linha que já começa com data e hora passa como está.
# Linha a linha, sem buffer (perl do macOS: o awk dele não tem strftime).
exec /usr/bin/perl -MPOSIX -ne 'BEGIN { $| = 1 }
  print /^\[?\d{4}-\d\d-\d\d[ T]\d\d:\d\d/ ? $_ : strftime("%Y-%m-%d %H:%M:%S ", localtime) . $_'

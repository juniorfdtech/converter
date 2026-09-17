# VOD Optimize

Conversor de vídeo para Linux/VPS focado em reduzir tamanho mantendo boa qualidade perceptual.

## Saída

- Container: Matroska (`.mkv`)
- Vídeo: AV1 10-bit (`libsvtav1`, fallback `libaom-av1`)
- Áudio: Opus (fallback AAC)
- Legendas: preservadas quando compatíveis; legendas textuais comuns são normalizadas para SRT
- Capítulos, metadados e anexos/fontes: preservados quando suportados
- Vídeo AV1 existente: stream-copy, evitando perda geracional
- Interlaced: detecção e desentrelaçamento com `bwdif`

## Instalação

```bash
chmod +x install-vod-optimize.sh vod-optimize.sh
sudo ./install-vod-optimize.sh
```

## Uso

```bash
vod-optimize filme.mp4
vod-optimize --profile quality /media/videos
vod-optimize --profile compact --output-dir /media/convertidos /media/videos
```

Perfis:

- `quality`: CRF 24 / SVT preset 4
- `balanced`: CRF 28 / SVT preset 6 (padrão)
- `compact`: CRF 32 / SVT preset 8

Use `--discard-larger` para descartar automaticamente uma saída que não fique menor que o arquivo original.

## Limitações importantes

O programa não promete ler literalmente todos os formatos já criados. Ele processa qualquer arquivo que a build instalada do FFmpeg consiga decodificar e que contenha uma faixa de vídeo. Dolby Vision e alguns metadados HDR proprietários exigem validação específica; AV1 genérico não é garantia de preservação integral desses metadados dinâmicos.

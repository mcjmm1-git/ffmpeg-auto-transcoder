# FFmpeg Auto Transcoder

Transcodificador automático de películas desarrollado en Bash utilizando FFmpeg y aceleración por hardware NVIDIA NVENC.

El objetivo del proyecto es automatizar completamente el proceso de conversión de una colección de películas a HEVC, reescalándolas a 4K cuando es necesario y manteniendo toda la información multimedia original.

---

## Características

- 🎬 Procesamiento automático de carpetas completas.
- 🚀 Codificación HEVC mediante NVIDIA NVENC.
- 📺 Reescalado automático hasta 3840×2160.
- 🎵 Conservación de todas las pistas de audio.
- 💬 Conservación de todos los subtítulos.
- 🌈 Compatibilidad con contenido HDR.
- 📊 Bitrate dinámico según la duración de la película.
- 📈 Monitor de progreso en tiempo real.
- 🎯 Watchdog para detectar bloqueos de FFmpeg.
- 🔄 Reintento automático cuando un filtro GPU no es compatible.
- 🎞️ Integración con TMDb.
- ⭐ Integración con OMDb.
- 📁 Publicación automática en Jellyfin.

---

## Requisitos

- Linux
- NVIDIA GPU compatible con NVENC
- FFmpeg
- ffprobe
- jq
- curl
- bc

---

## Estructura del proyecto

```
entrada/
procesadas/
terminadas/
errores/
logs/
jellyfin/
```

---

## Flujo de trabajo

1. Busca automáticamente todas las películas.
2. Analiza el archivo con ffprobe.
3. Consulta TMDb y OMDb.
4. Calcula un bitrate dinámico.
5. Codifica con HEVC NVENC.
6. Supervisa el progreso mediante un monitor en tiempo real.
7. Detecta bloqueos automáticamente.
8. Copia el resultado a Jellyfin.
9. Archiva el original.

---

## Estado

Proyecto en desarrollo activo.

Actualmente se utiliza para procesar automáticamente una colección personal de películas.

---

## Licencia

MIT

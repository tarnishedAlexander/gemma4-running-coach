# Gemma 4 Running Coach: Descripción General del Proyecto

## Descripción
El **Gemma 4 Running Coach** es una aplicación de entrenador de running con IA en tiempo real, contextual y ejecutada completamente en el dispositivo, diseñada para iOS (orientada al iPhone 16 Pro). Aprovecha las capacidades multimodales del modelo Gemma 4 E2B para proporcionar coaching en vivo, combinando entradas de texto, visión y audio de manera fluida, todo funcionando completamente en el dispositivo sin depender de conexión a internet (funciona incluso en modo avión).

## ¿De qué trata?
La aplicación transforma el iPhone del usuario en un compañero de running altamente inteligente. Al integrarse directamente con sensores de hardware (CoreLocation, CoreMotion, CoreBluetooth y HealthKit), la app monitorea continuamente métricas de carrera como ritmo, cadencia, cambios de elevación, frecuencia cardíaca, potencia de carrera y longitud de zancada. Estas métricas físicas en tiempo real se envían al modelo Gemma 4 cada 15 segundos, permitiendo que la IA ofrezca retroalimentación y recomendaciones personalizadas basadas en el contexto inmediato y el estado fisiológico del corredor.

## Características
- **Inferencia de IA en el dispositivo:** Privacidad total y funcionamiento offline al ejecutar el modelo Gemma 4 localmente en el iPhone.
- **Integración con sensores de hardware:**
  - **Ritmo:** Mapeo de velocidad GPS en tiempo real mediante CoreLocation.
  - **Cadencia:** Seguimiento de pasos por minuto (spm) usando CMPedometer (CoreMotion).
  - **Elevación:** Monitoreo de colinas mediante barómetro con CMAltimeter (CoreMotion).
  - **Frecuencia cardíaca:** Seguimiento en tiempo real (BPM) mediante CoreBluetooth para bandas pectorales.
  - **Dinámicas avanzadas de carrera:** Potencia de carrera (Watts) y longitud de zancada sincronizadas desde Apple Watch mediante HealthKit.
- **Memoria conversacional con ventana deslizante:** Gestión eficiente del contexto que mantiene ligeras las instrucciones del sistema y agrega nuevas métricas de sensores de manera orgánica, reduciendo drásticamente el tiempo de inferencia (de ~7s a ~0.4s).
- **Dos implementaciones paralelas:** Flexibilidad para utilizar `litert-lm` (wrapper Swift de LiteRT-LM) o `llama-cpp` según las necesidades de despliegue.
- **Soporte multimodal:** Capacidades para visión, audio (grabador de micrófono + pipeline WAV de 16 kHz) y procesamiento combinado de imagen/audio (principalmente en la implementación con `litert-lm`).
- **Modo de coaching en vivo:** Integración de Text-to-Speech (TTS), bucles de activación y audio en segundo plano para retroalimentación continua.

## Detalles del LLM
- **Modelo:** Gemma 4 E2B (multimodal)
- **Parámetros:** 4.65 mil millones de parámetros brutos / ~2 mil millones de parámetros efectivos.
- **Formato:** Funciona usando paquetes `.litertlm` (~2.6 GB) o formato GGUF (Q4_K_M, ~2.9 GB) con un proyector de visión.
- **Rendimiento:** Optimizado para inferencia limitada por ancho de banda de memoria, capaz de generar aproximadamente 15-20 tokens por segundo en un chip A18 Pro.

## Parte de Visión: Clasificador de Escenas para Seguridad
Para mejorar la seguridad del corredor, la aplicación incluye un **Clasificador de Escenas** impulsado por un modelo preentrenado **Vision Transformer (ViT)**.

### ¿Cómo funciona?
1. **Escaneo del entorno en tiempo real:** Utilizando la cámara del iPhone (potencialmente montado o sostenido durante la carrera), el modelo ViT procesa continuamente imágenes del entorno del corredor.
2. **Detección de peligros:** El clasificador está específicamente ajustado para reconocer objetos o situaciones peligrosas, tales como:
   - Vehículos acercándose (autos, bicicletas, scooters)
   - Obstáculos en el camino (zonas de construcción, escombros grandes, baches)
   - Cambios peligrosos en el terreno (zonas congeladas, desniveles repentinos)
   - Tráfico peatonal y posibles rutas de colisión
3. **Alertas proactivas:** Una vez que se detecta una amenaza con alta confianza, el sistema interrumpe o superpone inmediatamente el feedback estándar de coaching para emitir una advertencia audible urgente al usuario (por ejemplo: “Precaución: auto acercándose por detrás” o “Cuidado con los escombros de construcción adelante”), asegurando que el corredor mantenga conciencia situacional mientras se concentra en su entrenamiento.
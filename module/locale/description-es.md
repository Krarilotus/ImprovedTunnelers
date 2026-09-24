# Zapadores mejorados

Los zapadores comparten brechas, avanzan hacia la hoguera enemiga, atacan murallas, torres y puertas y restauran el terreno tras el derrumbe. Se pueden configurar el daño, los daños a edificios cercanos y una prohibición temporal de construir. Las unidades que excavan pueden excluirse de la selección y de los objetivos enemigos. En superficie, los zapadores reciben el botón de ataque, responden a las posturas defensiva/agresiva y participan en incursiones de IA configuradas para ellos.

Las funciones de juego están activadas por defecto; el diagnóstico está desactivado. Ajustes: Personalizaciones → Zapadores mejorados. Interfaz y ejecución comparten valores: 120 segundos de prohibición y 60 de daño a edificios cercanos. Se conservan los valores guardados. Reinicia el juego tras cambiar ajustes.

Los zapadores iniciales son una función separada y opcional de AI Swapper 1.5.0. Improved Tunnelers no crea tropas iniciales ni requiere AI Swapper. Para añadirlos, activa las tropas iniciales del puesto de IA en AI Swapper, configura su cantidad para Normal, Crusader o Deathmatch y comienza una partida nueva. Un campo vacío usa el paquete de IA; los paquetes normales no añaden ninguno. Cargar una partida no añade tropas. Fixed Engineers corrige por separado la limpieza y el desmontaje de tripulaciones de asedio.

Prueba rápida individual: recluta un zapador y compara su reacción ante enemigos cercanos con Posturas activado/desactivado. Para incursiones, usa una IA con gremio de zapadores y zapadores en sus ajustes de incursión. Prueba las cantidades iniciales por separado en AI Swapper. No actives al mismo tiempo el antiguo parche de zapadores de Unit Behaviour Fixes. Versión de prueba: faltan nuevas comprobaciones en el juego y revisión humana de las traducciones.

La versión 1.7.1 requiere Map Extensions 1.1.5. Empieza una partida nueva: las partidas guardadas antiguas carecen del estado de los tuneladores y se rechazan. Conserva los mismos módulos y ajustes al cargar o reproducir una repetición. Ahora se guardan los derrumbes pendientes, las rutas y las restricciones de construcción. Prueba: guarda durante un derrumbe, carga y compara con una partida sin interrupciones. La validación completa de las repeticiones sigue pendiente.

Una partida guardada renombrada a .map se puede seguir abriendo y editando como escenario. Los mapas inician un estado nuevo de los tuneladores; las partidas guardadas normales restauran las tareas en curso.

El terreno y la transitabilidad se restauran al terminar el túnel, antes del daño diferido. Así, el terreno del mapa no depende de una cola de túneles guardada. Sin el módulo, no continúan el daño pendiente ni las restricciones de construcción. La prueba en el editor del juego sigue pendiente.

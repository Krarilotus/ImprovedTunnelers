# Verbesserte Tunnelgräber

Tunnelgräber nutzen gemeinsame Breschen, graben zum gegnerischen Lagerfeuer weiter, greifen Mauern, Türme und Tore an und stellen den Boden nach dem Einsturz wieder her. Einsturzschaden, Schaden an benachbarten Gebäuden und eine vorübergehende Bausperre sind einstellbar. Grabende Einheiten können von Auswahl und gegnerischen Angriffen ausgeschlossen werden. Oberirdisch erhalten Tunnelgräber den Angriffsbefehl, reagieren auf defensive/aggressive Haltung und nehmen an KI-Überfällen teil, wenn sie dort eingestellt sind.

Spielfunktionen sind bei Auswahl standardmäßig AN, Diagnose ist AUS. Einstellungen: Anpassungen → Verbesserte Tunnelgräber. Oberfläche und Laufzeit verwenden dieselben Vorgaben: 120 Sekunden Bausperre und 60 Schaden an Nachbargebäuden. Gespeicherte Werte bleiben erhalten. Nach Änderungen das Spiel neu starten.

Start-Tunnelgräber sind eine separate, optionale Funktion von AI Swapper 1.5.0. Improved Tunnelers erzeugt keine Starttruppen und benötigt AI Swapper nicht. Dafür im gewünschten KI-Platz dessen Starttruppen-Komponente aktivieren, die Tunnelgräberzahl für Normal, Crusader oder Deathmatch setzen und eine neue Partie beginnen. Leere Werte übernehmen das KI-Paket; gewöhnliche Pakete geben keine hinzu. Laden fügt keine Truppen hinzu. Fixed Engineers korrigiert unabhängig davon Besatzungsbereinigung und Aussteigen.

Kurzer Einzelspielertest: einen Tunnelgräber rekrutieren und seine Reaktion auf nahe Gegner mit Haltung AN/AUS vergleichen. Überfälle mit einer KI testen, die eine Tunnelgräbergilde und Tunnelgräber in ihren Überfalleinstellungen besitzt. Startzahlen separat über AI Swapper prüfen. Die alte Tunnelgräberkorrektur aus Unit Behaviour Fixes nicht gleichzeitig aktivieren. Testkandidat: neue Spieltests und menschliche Übersetzungsprüfung stehen noch aus.

Version 1.7.1 benötigt Map Extensions 1.1.5. Starte eine neue Partie: Alten Spielständen fehlen die Tunnelerdaten, deshalb werden sie abgelehnt. Behalte beim Laden und bei Replays dieselben Modulpakete und Einstellungen. Laufende Einstürze, Routen und Bausperren werden nun gespeichert. Test: Während eines Einsturzes speichern, laden und mit ununterbrochenem Spiel vergleichen. Die vollständige Replay-Prüfung steht noch aus.

Ein in .map umbenannter Spielstand kann weiterhin als Szenario geöffnet und bearbeitet werden. Karten beginnen mit frischen Tunnelerdaten; normale Spielstände stellen laufende Vorgänge wieder her.

Gelände und Begehbarkeit werden beim Abschluss eines Tunnels wiederhergestellt, vor dem verzögerten Schaden. Das Kartengelände hängt damit nicht von einer gespeicherten Tunnelwarteschlange ab. Ohne das Modul werden ausstehender Schaden und Baubeschränkungen nicht fortgesetzt. Der Test im Spiel-Editor steht noch aus.

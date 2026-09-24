# Fejlesztett alagútásók

Az alagútásók közös réseket használnak, az ellenséges tábortűz felé haladnak, falakat, tornyokat és kapukat céloznak, és az omlás után helyreállítják a talajt. Beállítható az omlás sebzése, a közeli épületek sebzése és az ideiglenes építési tilalom. Az ásó egységek kizárhatók a kijelölésből és az ellenség célpontjai közül. A felszínen támadógombot kapnak, követik a védekező/támadó magatartást, és részt vesznek az őket tartalmazó MI-portyákban.

A játékfunkciók alapból BE, a diagnosztika KI állású. Beállítások: Testreszabások → Fejlesztett alagútásók. A felület és a futás alapértékei egyeznek: 120 másodperc építési tilalom és 60 sebzés a közeli épületeknek. A mentett értékek megmaradnak. Változtatás után indítsd újra a játékot.

A kezdő alagútásók az AI Swapper 1.5.0 külön, választható funkciója. Az Improved Tunnelers nem hoz létre kezdőcsapatokat, és nem igényli az AI Swappert. Hozzáadáshoz engedélyezd az adott MI-hely kezdőcsapatait az AI Swapperben, állítsd be a Normal, Crusader vagy Deathmatch létszámot, és indíts új játékot. Az üres mező az MI-csomagot követi; a szokásos csomagok nem adnak alagútásókat. Mentés betöltése nem ad egységeket. A Fixed Engineers külön javítja az ostromgépek kezelőinek feldolgozását és kiszállását.

Rövid egyjátékos teszt: toborozz egy alagútásót, és hasonlítsd össze közeli ellenségre adott reakcióját a magatartások BE/KI állásában. Portyához legyen az MI-nek alagútásó céhe és alagútásó a portyabeállításaiban. A kezdőlétszámot külön teszteld az AI Swapperben. A Unit Behaviour Fixes régi alagútásó-javítását ne engedélyezd ezzel együtt. Tesztverzió; az új játékon belüli ellenőrzés és az emberi fordításellenőrzés még hátravan.

Az 1.7.0 verzióhoz Map Extensions 1.1.5 szükséges. Kezdj új játékot: a régi mentésekből hiányzik az alagútásók állapota, ezért a modul elutasítja őket. Betöltéshez és visszajátszáshoz tartsd meg ugyanazokat a modulcsomagokat és beállításokat. A folyamatban lévő omlások, útvonalak és építési tilalmak most már mentésre kerülnek. Teszt: ments omlás közben, töltsd vissza, és hasonlítsd össze a megszakítás nélküli játékkal. A teljes visszajátszási ellenőrzés még hátravan.

A .map kiterjesztésűre átnevezett mentés továbbra is megnyitható és szerkeszthető pályaként. A pályák friss alagútásó-állapottal indulnak; a normál mentések visszaállítják a folyamatban lévő munkát.

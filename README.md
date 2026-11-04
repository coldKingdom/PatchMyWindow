# PatchMyWindow

Ett fristående svenskt WPF-gränssnitt för att uppdatera en offline Windows 11-image och dess **WinRE med Safe OS Dynamic Update**, med **Windows PowerShell 5.1** och Windows inbyggda DISM-modul. Inga externa PowerShell-moduler eller GUI-paket behöver installeras.

## Starta

Dubbelklicka på **Start-PatchMyWindow.cmd** och godkänn administratörsbehörighet i Windows UAC-dialog. Behåll `PatchMyWindow.ps1`, `PatchMyWindow.Core.psm1` och `MainWindow.xaml` i samma mapp som startfilen.

Startfilen väljer 64-bitars Windows PowerShell och STA-läge. ExecutionPolicy Bypass gäller bara den startade processen; datorns permanenta policy ändras inte. En centralt framtvingad policy kan kräva att skripten signeras av organisationen.

För en skrivskyddad förhandsvisning, utan administratörsrättigheter:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\PatchMyWindow.ps1 -Preview
```

## Arbetsflöde

1. **Välj image:** öppna `install.wim` eller `install.esd` och välj Windows-utgåva. För ISO-media: montera ISO-filen i Utforskaren och välj image-filen under `sources`.
2. **Välj resultatfil:** ange ett nytt `.wim`-filnamn. Resultatet innehåller endast vald utgåva, på index 1. Befintliga filer skrivs inte över.
3. **Skapa arbetskopia och montera:** vald utgåva exporteras och monteras med integritetskontroll. Källfilen ändras inte.
4. **Lägg till paket:** välj mål **Windows / install.wim** eller **Safe OS / WinRE** och lägg till lokala `.msu`- eller `.cab`-filer. Målen har separata köer. Använd pilarna för att placera förkrav/checkpoints före beroende uppdateringar. Kör respektive kö med **Installera paket** eller **Installera i WinRE**.
5. **Granska och spara:** kontrollera båda köernas paketstatus och logg samt inställningarna under **Avslutning**. Standardvalen är komponentrensning och WIM-kompaktering. Välj **Spara och avmontera**. WinRE avslutas först, därefter Windows. Vänta på slutstatus och granska eventuella anmärkningar innan resultatet används.

Arbetsmappen och resultatfilen måste ligga på en lokal, fast NTFS-disk. Utrymmeskontrollen reserverar konservativt bildens okomprimerade storlek plus 10 GB på varje använd disk, eller dubbelt detta om arbetsmapp och resultat delar disk. Standardarbetsmapp: `%LOCALAPPDATA%\PatchMyWindow`. Välj **Byt…** för en rymligare disk. Resultatfilen ska ligga utanför arbetsmappen.

## Kö, loggar och återupptagning

- DISM körs i en separat PowerShell-runspace. Gränssnittet förblir tillgängligt; aktivitetsindikatorn visar pågående arbete utan att gissa procent.
- Kön stannar vid första paketfel. Redan installerade paket ligger kvar i den monterade imagen. Fel visas i gränssnittet och loggas.
- **Stoppa efter paketet** stoppar före nästa paket. En pågående DISM-operation avbryts inte mitt i en skrivning.
- **Ta bort ur kön** tar endast bort raden. Det avinstallerar inte ett paket som redan lagts till i imagen.
- När en paketkörning börjar sparas hela den begärda kön, inklusive ännu inte påbörjade paket. En kö som bara lagts till i gränssnittet men aldrig körts finns endast i minnet.
- Öppna samma arbetsmapp för att återuppta en session. Verktyget kontrollerar att monteringssökväg, image-fil och index matchar innan ändringar tillåts. En kvarvarande montering som behöver återanslutas får en särskild knapp.
- Ett paket som var pågående vid ett oväntat avbrott visas som **Kontrollera**. Kontrollera DISM-loggen före ett nytt försök; det kan ha hunnit installeras.
- **Kasta ändringar** avmonterar WinRE först och därefter Windows utan att spara. Original, arbetsfiler och loggar behålls. En exportfil från en misslyckad eller kastad session är inte ett verifierat patchresultat; använd ett nytt resultatnamn för nästa försök.
- Programmet blockerar normal stängning medan DISM arbetar. Om du stänger mellan operationer kan sessionen lämnas monterad för återupptagning.

Varje session har `activity.log` och `dism.log` under arbetsmappens `Sessions\<id>`. Knappen **Öppna sessionsloggar** öppnar mappen. `active-session.json` sparas atomiskt med en `.bak` av föregående version. Ingen automatisk radering av arbetsmappar görs. Radera aldrig en mapp som fortfarande är monterad av DISM.

## Språkpaket och LXP

Välj **Språkpaket / LP och LIP** i målmenyn, lägg till CAB-filer från Languages and Optional Features-media för rätt Windows-version och arkitektur och välj **Installera språkpaket**. DISM kontrollerar paketens ReleaseType före installation. Lägg ett LIP:s nödvändiga basspråk först i kön. Windows Home Single Language stöder inte att ytterligare visningsspråk läggs till.

Efter varje påbörjad språkändring krävs **Återapplicera CU efter språkändringar…** före sparning, cleanup och ResetBase. Välj den senaste kumulativa uppdateringen för imagen; håll nödvändiga checkpoint-paket i samma paketmapp enligt Microsofts anvisningar. Verktyget kör Add-WindowsPackage igen även om den CU-filen redan finns i historiken. Fel eller avbruten körning lämnar kravet kvar. Filtypen visar inte att paketet är en CU: operatören måste välja rätt uppdatering. Språk som läggs in via den vanliga Windows-kön omfattas inte av denna särskilda kontroll; använd språkkön för LP/LIP.

Språkfunktioner/FOD såsom Basic, OCR och tal samt automatisk konfigurering av standardspråk ingår ännu inte i detta språkflöde. Hantera nödvändiga FOD från matchande media innan sista CU-körningen. WinRE-språkpaket hanteras separat i WinRE-kön.

**LXP:** välj **Provisionera LXP (APPX/MSIX)…**, välj huvudpaketet, dess XML-licens och eventuella beroendepaket. Avbryt beroendevalet om inga behövs. Efter granskning körs `Add-AppxProvisionedPackage -Path <monterad Windows-image> -PackagePath ... -LicensePath ... -Regions all`, med `-DependencyPackagePath` när beroenden valts. Verktyget använder varken `-Online` eller `-SkipLicense`. Status och valda filer journalförs. CU-återapplicering krävs före avslutning även efter denna språkändring. Vid fel lämnas imagen monterad och samma flöde kan köras igen med korrigerade filer.

Cmdleten provisionerar paket för användare i mål-Windows; den byter inte automatiskt visningsspråk. Paket, licens, beroenden och basspråk måste passa målversionen. Verktyget verifierar filernas existens och format, men identifierar inte automatiskt att ett APPX/MSIX-paket är ett LXP. Testa er specifika paketkombination i en VM. Generellt stöd för APPX-provisionering innebär inte att alla LXP-versioner stöds för Windows 11-imaging. [Add-AppxProvisionedPackage](https://learn.microsoft.com/powershell/module/dism/add-appxprovisionedpackage).

Microsoft dokumenterar CAB-baserade LP/LIP för Windows 11-imaging och APPX-baserade språk via Inställningar efter inloggning: [Lägg till språk i Windows-imager](https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-language-packs-to-windows?view=windows-11). Samma sida beskriver kravet att återinstallera LCU efter språkpaket.

## Uppdatera inbox-appar

Öppna **Inbox-appar · provisionerade APPX/MSIX-paket** och klicka **Läs appar och versioner**. Listan kommer från `Get-AppxProvisionedPackage -Path` och visar namn, version och arkitektur för provisionerade paket i den monterade Windows-imagen.

Välj **Uppdatera / provisionera app…**, välj det kompatibla nyare huvudpaketet, dess XML-licens och eventuella beroenden. Samma offline-API som för LXP används: `Add-AppxProvisionedPackage -Path`, med `LicensePath`, valfria `DependencyPackagePath` och `Regions all`. Inga gamla paket avinstalleras automatiskt. DISM avgör om paketet kan provisioneras. Läs applistan igen efter körningen för att granska versionerna.

Appfiler hämtas separat från en betrodd distributionskälla. Automatisk sökning/nedladdning av uppdateringar, EXE/MSI-installationer och appar som inte är provisionerade APPX/MSIX-paket ingår inte. Detta flöde kräver XML-licens; `SkipLicense` används inte. Paketets identitet, målversion, arkitektur och beroenden måste stämma. Prova den färdiga imagen i en VM, inklusive första inloggning.

Appåtgärder journalförs separat från LXP och ändrar inte språkens CU-krav. En vanlig appuppdatering utlöser inte CU-återapplicering och kan inte heller rensa ett redan befintligt språkkrav. LXP ska därför alltid installeras via LXP-knappen. Vid fel behålls imagen monterad; rätta filvalet och kör igen. Appändringarna blir permanenta i WIM-filen först vid **Spara och avmontera**.

## Safe OS-installation

Välj **Safe OS / WinRE** i målmenyn under Uppdateringspaket. Lägg till Safe OS Dynamic Update för rätt Windows-version och arkitektur från Microsoft Update Catalog, normalt en CAB-fil. Eventuella WinRE-förkrav, till exempel en föreskriven servicing stack-uppdatering, läggs före Safe OS-paketet i samma kö. Läs paketets KB-instruktioner. Målmenyn styr vart paketen installeras; pakettyp och beroenden identifieras inte automatiskt från filnamnet. Setup Dynamic Update hör inte hemma i denna kö.

Verktyget hämtar `Windows\System32\Recovery\winre.wim` från den monterade Windows-utgåvan till sessionens egen arbetsfil `winre.wim`. Den monteras på index 1 i `WinREMount`, och Safe OS-paketen installeras där. Saknas den inbäddade filen stoppas operationen med ett felmeddelande.

WinRE lämnas monterad efter paketkörningen så att fler paket kan läggas till. **Klart** på en paketrad betyder att DISM accepterade installationen i den monterade miljön; resultatfilen är färdig först efter **Spara och avmontera**. Då sparas WinRE-arbetsfilen, kopieras tillbaka till den monterade Windows-utgåvan, och sist sparas Windows-imagen. Om WinRE-sparning eller återkopiering misslyckas förblir Windows-imagen monterad. Ett fel vid återkopiering kan återförsökas med **Spara och avmontera**.

Båda monteringar kontrolleras när sessionen återupptas. **Återanslut montering** hanterar även WinRE. Om en tidigare aktiv WinRE-montering helt saknas blockeras sparning för att inte tappa ändringarna obemärkt; kasta sessionen och börja om. Gamla sessionsfiler läses och uppgraderas till format 6 vid nästa skrivning. Öppna därefter sessionen med denna eller en nyare programversion.

Bearbetad WinRE omfattas av avslutningsinställningarna nedan. Kontrollera fortfarande att den resulterande WinRE-imagen ryms i återställningspartitionen i ditt distributionsupplägg.

## Avslutning, cleanup och ResetBase

Under **Avslutning** finns tre val som gäller Windows och bearbetad WinRE:

- **Standard · StartComponentCleanup** är förvalt. DISM rensar ersatta komponenter före sparning.
- **StartComponentCleanup + ResetBase** är ett aktivt tillval. Befintliga uppdateringar kan inte avinstalleras i resultatet efter ResetBase. Framtida uppdateringar omfattas inte av denna begränsning. Originalimagen bevaras fortfarande. Konsekvensen visas vid valet och i sparbekräftelsen.
- **Ingen komponentrensning** sparar utan cleanup, exempelvis om du vill hantera rensningen separat.

**Kompaktera WIM-filer genom export efter sparning** är förvalt och kan stängas av. Med standardinställningar sker avslutningen så här:

1. Kontrollera väntande paket- och funktionsåtgärder i monterad WinRE, och kör cleanup om det går.
2. Spara och avmontera WinRE med integritetskontroll.
3. Exportera WinRE till en ny WIM med maximal komprimering och integritetskontroll, och ersätt arbetsfilen först när exporten lyckats.
4. Kopiera WinRE tillbaka till Windows-imagen.
5. Kontrollera väntande åtgärder och kör cleanup i Windows-imagen.
6. Spara och avmontera Windows-imagen med integritetskontroll.
7. Exportera Windows-imagen till en ny WIM och ersätt resultatfilen först när exporten lyckats.

WinRE-stegen används endast om WinRE bearbetats i sessionen. Verktyget använder `Repair-WindowsImage -Path ... -StartComponentCleanup -NoRestart`, med `-ResetBase` endast när du valt det. `-Defer` används inte: det är avsett för särskilda fabriksflöden, och här ska rensningen slutföras före export. `-Online` och `-RevertPendingActions` används aldrig.

**Väntande åtgärder:** paket-/funktionsstatus med `Pending` eller en kvarvarande `Windows\WinSxS\pending.xml` gör att cleanup och ResetBase hoppas över för just den miljön. Sparning och export kan fortsätta, men resultatet markeras **sparat med anmärkning** i statusraden, sessionsfilen och loggen. Detta är relevant efter exempelvis vissa .NET- eller optional component-installationer. Verktyget tar inte bort väntande åtgärder. Om cleanup krävs för din leverans, följ Microsofts serviceordning där sådana tillägg läggs efter cleanup, eller slutför de väntande åtgärderna i en separat startad testmiljö innan fortsatt imagearbete. Verktyget automatiserar inte det senare flödet.

Om inspektion eller cleanup misslyckas med ett annat fel stoppas avslutningen och berörd image lämnas monterad. En lyckad cleanup journalförs och behöver inte upprepas när en efterföljande sparning återförsöks; nya paket gör att cleanup behövs igen.

**Export och återupptagning:** vid exportfel behålls den senast sparade WIM-filen. Om Windows redan är avmonterad visas **Slutför avslutningen**. Då återförsöks exporten utan att köra cleanup eller commit igen. Du kan också stänga av kompakteringen och slutföra med den redan sparade filen. Redan sparade ändringar kan inte kastas i detta läge.

Export kräver extra ledigt utrymme. Föregående sparade WIM behålls bredvid respektive arbets-/resultatfil som `*.before-compact-<id>.bak`. En misslyckad export kan lämna `*.compact-<id>.wim`. Filnamnen loggas. Dessa extrafiler kan tas bort efter granskning när sessionen är avslutad; verktyget raderar dem inte automatiskt.

## Omfattning och förutsättningar

- Kör på Windows 11 med 64-bitars Windows PowerShell 5.1, .NET Framework/WPF och DISM. Använd en värd/DISM-version som stöder den image-version som ska bearbetas.
- Uppdateringsfiler hämtas separat. Använd rätt Windows-version, arkitektur och paketberoenden. DISM:s kompatibilitetskontroll kringgås inte.
- Windows 11 24H2 och senare kan kräva checkpoint-uppdateringar. Hämta även nödvändiga förkrav från Microsoft Update Catalog och installera dem i angiven ordning.
- Verktyget bearbetar en vald utgåva och dess inbäddade WinRE åt gången. Det bygger inte en startbar ISO och uppdaterar inte automatiskt `boot.wim`, Setup Dynamic Update eller övriga utgåvor. Det hanterar inte delade SWM-filer eller krypterade ESD-filer.
- Vissa paket kräver att imagen startas för att slutföra väntande åtgärder. Verktyget startar inte om värddatorn och använder inte DISM `-Online`.
- En session kan vara aktiv per arbetsmapp. Använd en separat arbetsmapp per operatör; kör inte andra serviceverktyg mot samma montering samtidigt.

## Verifiering

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\PatchMyWindow.ps1 -SmokeTest
```

Testerna körs utan extra testbibliotek. De ersätter DISM-kommandon med testdubblar och kontrollerar bland annat filskydd, exportindex, separata Windows/WinRE-mål, paketordning, paketfel, stopp mellan paket, sessionsåterställning, främmande monteringar, sparfel, återkopiering av WinRE och kassering. Avslutningstester kontrollerar cleanup före commit, explicit ResetBase, väntande paket/funktioner/pending.xml, cleanup-fel, exportfel, bevarad WIM och återupptagning efter commit. UI-testet laddar riktig WPF i PowerShell 5.1 och kontrollerar köer, standardinställningar, ResetBase-information och åtgärdernas tillgänglighet under körning och återställning.

**Ingen riktig Windows-image ingår i projektet. Fullständig export, patchning och commit mot en riktig WIM har därför inte verifierats här.** Testa resultatet i en virtuell maskin innan det används för distribution.

## Microsoft-dokumentation

- [DISM PowerShell](https://learn.microsoft.com/powershell/module/dism/)
- [Export-WindowsImage](https://learn.microsoft.com/powershell/module/dism/export-windowsimage)
- [Add-WindowsPackage](https://learn.microsoft.com/powershell/module/dism/add-windowspackage)
- [Checkpoint cumulative updates](https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates)
- [Uppdatera hela installationsmediet med Dynamic Update](https://learn.microsoft.com/windows/deployment/update/media-dynamic-update)
- [Komponentrensning i offline-imager](https://learn.microsoft.com/windows-hardware/manufacture/desktop/reduce-the-size-of-the-component-store-in-an-offline-windows-image)
- [DISM cleanup, ResetBase och Defer](https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-operating-system-package-servicing-command-line-options)
- [Repair-WindowsImage](https://learn.microsoft.com/powershell/module/dism/repair-windowsimage)

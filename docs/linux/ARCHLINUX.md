# AirCard no Arch Linux

Esta versão inclui interface gráfica e CLI nativas em Rust, usando USB pelo
`usbmuxd`. Funciona em sessões Wayland ou X11; não precisa de macOS, Wine,
Swift, Python nem bibliotecas da Apple para executar o cliente Linux.

O transporte Linux vem de [AirCard-Linux](https://github.com/shinkuan/AirCard-Linux).
Veja os [créditos e a versão importada](ATTRIBUTION.md).
A compatibilidade com o iPhone depende da versão do iOS e do protocolo AirLift.
Compilar ou abrir a interface não comprova que uma imagem foi aplicada no iPhone.

## Instalação

```bash
sudo pacman -S --needed base-devel rust git usbmuxd libimobiledevice \
    libxkbcommon libglvnd wayland libx11 libxcursor libxi libxrandr \
    xdg-desktop-portal
git clone https://github.com/Mak5er/AirCard.git
cd AirCard/packaging/arch
CARGO_BUILD_JOBS=2 makepkg -si
```

Execute `makepkg` como usuário normal. O pacote instala `aircard`, `aircard-gui`
e um atalho AirCard no menu de aplicativos. Não foi publicado no AUR.
O limite de dois jobs reduz o pico de memória durante a compilação.

O seletor de arquivos precisa de um backend de portal adequado ao desktop.
No Hyprland, `xdg-desktop-portal-hyprland` costuma trabalhar junto com
`xdg-desktop-portal-gtk` para fornecer o seletor; no KDE use o backend KDE.
Se faltar o seletor no Hyprland:

```bash
sudo pacman -S --needed xdg-desktop-portal-gtk
```

Encerre e reabra a sessão se acabou de instalar o backend.

## Conectar e usar

1. Conecte o iPhone por cabo USB de dados e desbloqueie a tela.
2. Execute `idevicepair pair`, aceite **Confiar** no iPhone e, se necessário,
   execute novamente. Confira com `idevicepair validate`.
3. Execute `aircard devices` e abra `aircard-gui`.
4. Na aba Wallet, selecione o aparelho e clique **Scan**. Abra o Wallet no
   iPhone, autentique e toque no cartão. Clique **Stop** depois da detecção.
5. Escolha o cartão e a imagem. Confira a prévia e clique **Apply Card Skin**.
6. Aguarde o resultado. Feche o Wallet pelo seletor de aplicativos do iPhone
   e abra novamente; se necessário, reinicie o aparelho.

Na aba Passcode, é possível selecionar um arquivo `.passthm`, configurar
idioma/Bold Text e aplicar o tema. O Linux importado não oferece o editor
SwiftUI de criação de temas do aplicativo macOS.

Pelo terminal:

```bash
aircard devices
aircard probe                       # handshake sem aplicar imagens
aircard scan                        # Ctrl-C encerra
aircard card '<hash-detectado>' ~/Pictures/cartao.png
aircard theme ~/Themes/tema.passthm --language Universal
```

Use `--udid <UDID>` nos comandos que operam em um aparelho quando houver mais
de um conectado. Imagens PNG, JPEG e WebP são recortadas ao centro para
1536 × 969. Os cartões ficam em `$XDG_DATA_HOME/aircard/cards.json`, normalmente
`~/.local/share/aircard/cards.json`.

## Diagnóstico

O `usbmuxd` do Arch inicia sob demanda pelas regras udev. Estar inativo sem
iPhone conectado é normal. Com o aparelho conectado, consulte:

```bash
systemctl status usbmuxd
journalctl -u usbmuxd -n 30
idevice_id -l
idevicepair validate
aircard devices
```

Se não houver dispositivo, confira o cabo, o desbloqueio e a confirmação de
confiança. Se **Scan** não detectar cartões, valores ocultos como `<private>`
nos logs do iOS não podem ser recuperados pelo scanner. Não compartilhe logs
integrais nem identificadores de cartões.

## Compilar sem instalar

Na raiz do repositório:

```bash
cargo build --release --locked --workspace -j 2
./target/release/aircard --help
./target/release/aircard-gui
```

Para executar os testes do cliente Linux:

```bash
cargo test --release --locked --workspace -j 2
```

Os testes automatizados cobrem lógica local; o teste de detecção e aplicação
real exige um iPhone conectado e deve ser confirmado no próprio aparelho.

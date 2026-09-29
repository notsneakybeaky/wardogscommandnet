Wardogs Command Net

Everything was made using Claude. I made this because I thought people would use for their competitive matches it but realized no one would use install batch files for their comp teams or in general. However this is cheaper and more customizable than a TeamSpeak server or Discord because the files can run directly next to your server files (whenever they add that). Maybe it can be expanded so that people automatically connect through steam-ids by using the rcon api. All of this wouldn't be required if they would've just added the option to have a command net in the beginning anyway. When you create your channel it also allows you to rename your channel. Also, because Project Reality runs mumble really well and I think its a powerful undervalued software that I just wanted to mess with for a couple hours.

Mumble voice setup with squads. Whoever creates a squad is the squad leader. B talks to your squad, V talks to all squad leaders.

----

Server setup (Ubuntu/Debian with mumble-server, do once)

1. SSH into the server.
2. sudo apt install -y git
3. git clone https://github.com/YOUR-NAME/wardogs-command-net
4. sudo SQUADS=4 bash wardogs-command-net/server/install.sh (SQUADS is the max number of squads, 0 for no limit)
5. Mumble restarts once, anyone connected gets kicked for a second.
6. Check it's running: systemctl status squad-bot
7. Watch it live: journalctl -u squad-bot -f

----

Client setup with the installer (Windows)

1. Click Code > Download ZIP on this page, right-click the zip > Extract All.
2. Open the client folder, right-click Install-WardogsCommandNet.ps1 > Open with > Notepad.
3. Replace YOUR.SERVER.IP with the server address from your admin, save, close Notepad.
4. Double-click Install Wardogs Command Net.bat. If Windows warns you, click More info > Run anyway.
5. Use the Wardogs Command Net icon on your desktop to connect and type your name.

----

Client setup without the installer

1. Install Mumble from mumble.info.
2. Open Mumble, go to Server > Connect > Add New.
3. Address: the server address from your admin. Port: 64738. Username: your name. Click OK, then Connect.
4. Click Yes on the certificate warning.
5. Go to Configure > Settings > Audio Input and set Transmit to Push To Talk.
6. Go to Shortcuts, click Add, set Function to Push-to-Talk, double-click the Shortcut cell and press B.
7. Stay connected to the server for this step. Click Add again and set Function to Whisper/Shout.
8. Double-click the Data cell, pick Shout to Channel, click Root, tick Shout to subchannels, type sl in Restrict to Group, click OK.
9. Double-click the Shortcut cell and press V.
10. Click OK to save.

----

Using it

1. Hold B to talk to your squad.
2. To make a squad, right-click the top channel > Add, type a name, click OK. You are now squad leader.
3. As squad leader, hold V to talk to the other squad leaders.
4. Double-click a squad to join it.
5. To hand over squad lead, type !sl name in your squad's chat.

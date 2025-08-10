<img width="1261" height="410" alt="image" src="https://github.com/user-attachments/assets/b924e8e9-0187-4207-b2d3-ad43e447b0ac" />
# heppy ssh connector
SSH script for members of yetanotherprojecttosavetheworld.org to access any ssh server from the bot happy to execute limited commands on limited file paths. 
and my internal scripts for security reference 

## how to install

copy heppy-ai-ssh-wrapper.sh to the ~/bin dir (bin in your home directory) 

make a config folder ~/.config/heppy_ai/

and place and edit the config/auth.conf (in this git source) in that folder.

generate a auth key
`./bin/eppy-ai-ssh-wrapper.sh --keygen`

add this line to your `~/.ssh/authorized_keys`
`command="/home/heppy/bin/heppy-ai-ssh-wrapper.sh --exec $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,no-user-rc,no-agent-forwarding ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDHpqx731NRoFkMskCZW/4E9FLgHepv2PH2+CZfxrgGo9kDPWDTnhykJ0na7H57Nd0gDkto9Ro/EDC0Bg8VGMW1ziP8V5AKFrBGWKcST5MQuTtWu6U5evvwEXYmMNHJld4EiQ/zEKJYXayM3cLieMlNR1orui9/voCr5uAa4bjKzYC09Z6fh5fN8ZzhQ+QcbxL1Vsfpkr/a9UyjD2G9fM7hC0Q/9/NOF1WUNhVlbTHGinjPOok7RYze2I1MdPno0PgWpRYIpNaYzmsSN95Ox9DTn0d6YmuBkTjh24eVslsHHOcQOETXeZBX+dppOD5QisTIpiWAaR8rxswsUQ54iK6d3//2ycVCZWl1kv0KVE4eIqfx5cIJukFVtRAByOCXkh+EVG8iFlJhm2rHGOHgPPpF/WKcOmsszXAVCcvG4uZMoMLPDY/Mo+twpBjg4CB5/OsWFQZ/45CF5qB2RkvynsacHfbt9yyvvH0jqMwRDyKoyg4klumGiLOVoxp8AQ5M+Kk= root@heppy`

goto https://www.yetanotherprojecttosavetheworld.org/ssh_management.php

and add your server to the list.

press test.

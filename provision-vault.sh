#!/bin/bash
set -eux
export PATH=$PATH:/usr/local/bin
# add the vault user.
useradd -r -m -d /opt/vault vault


# install vault.
curl -s https://releases.hashicorp.com/vault/1.4.0/vault_1.4.0_linux_amd64.zip > /tmp/vault.zip
cd /tmp
unzip vault.zip
install -d /opt/vault/bin
cp vault /opt/vault/bin
ln -s /opt/vault/bin/vault /usr/local/bin
rm vault.zip

# run as a service.
# see https://www.vaultproject.io/guides/production.html
# see https://www.vaultproject.io/docs/internals/security.html
cat >/etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=Vault
After=network.target

[Service]
Type=simple
User=vault
Group=vault
PermissionsStartOnly=true
ExecStart=/opt/vault/bin/vault server -config=/opt/vault/etc/vault.hcl
ExecStartPost=/opt/vault/bin/vault-unseal
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# configure.
domain=$(hostname --fqdn)
export VAULT_ADDR="https://$domain:8200"
echo export VAULT_ADDR="https://$domain:8200" >>~/.bash_login
install -o vault -g vault -m 700 -d /opt/vault/data
install -o root -g vault -m 750 -d /opt/vault/etc
install -o root -g vault -m 440 /opt/pki/ca/vault.pem /opt/vault/etc
install -o root -g vault -m 440 /opt/pki/ca/vault-key.pem /opt/vault/etc
install -o root -g vault -m 640 /dev/null /opt/vault/etc/vault.hcl
cat >/opt/vault/etc/vault.hcl <<EOF
cluster_name = "example"
disable_mlock = true
ui = true

# one of: trace, debug, info, warning, error.
log_level = "trace"

storage "file" {
    path = "/opt/vault/data"
}

listener "tcp" {
    address = "0.0.0.0:8200"
    tls_disable = false
    tls_cert_file = "/opt/vault/etc/vault.pem"
    tls_key_file = "/opt/vault/etc/vault-key.pem"
}
EOF
install -o root -g root -m 700 /dev/null /opt/vault/bin/vault-unseal
echo '#!/bin/bash' >/opt/vault/bin/vault-unseal

# disable swap.
swapoff --all
sed -i -E 's,^(\s*[^#].+\sswap.+),#\1,g' /etc/fstab

# start vault.
systemctl enable vault
systemctl start vault
sleep 3
journalctl -u vault

# init vault.
# NB vault-operator-init-result.txt will have something like:
#       Unseal Key 1: sXiqMfCPiRNGvo+tEoHVGy+FHFW092H7vfOY0wPrzpYh
#       Unseal Key 2: dCm5+NhacPcX6GwI0IMMK+CM0xL6wif5/k0LJ0XTPHhy
#       Unseal Key 3: YjbM3TANam0dO9FTa0y/2wj7nxnlDyct7oVMksHs7trE
#       Unseal Key 4: CxWG0yrF75cIYsKvWQBku8klN9oPaPJDWqO7l7LNWX2A
#       Unseal Key 5: C+ttQv3KeViOkIxVZH7gXuZ7iZPKi0va1/lUBSiMeyLz
#       Initial Root Token: d2bb2175-2264-d18b-e8d8-18b1d8b61278
#
#       Vault initialized with 5 keys and a key threshold of 3. Please
#       securely distribute the above keys. When the vault is re-sealed,
#       restarted, or stopped, you must provide at least 3 of these keys
#       to unseal it again.
#
#       Vault does not store the master key. Without at least 3 keys,
#       your vault will remain permanently sealed.
cd
install -o root -g root -m 600 /dev/null vault-operator-init-result.txt
install -o root -g root -m 600 /dev/null /opt/vault/etc/vault-unseal-keys.txt
install -o root -g root -m 600 /dev/null .vault-token
vault operator init >vault-operator-init-result.txt
awk '/Unseal Key [0-9]+: /{print $4}' vault-operator-init-result.txt | head -3 >/opt/vault/etc/vault-unseal-keys.txt
awk '/Initial Root Token: /{print $4}' vault-operator-init-result.txt >.vault-token
#cp .vault-token /vagrant/shared/vault-root-token.txt
#popd
cat >/opt/vault/bin/vault-unseal <<EOF
#!/bin/bash
set -eu
sleep 3 # to give vault some time to initialize before we hit its api.
KEYS=\$(cat /opt/vault/etc/vault-unseal-keys.txt)
for key in \$KEYS; do
    /opt/vault/bin/vault operator unseal -address=$VAULT_ADDR \$key
done
EOF
/opt/vault/bin/vault-unseal

# restart vault to verify that the automatic unseal is working.
systemctl restart vault
sleep 3
journalctl -u vault
vault status

# enable auditing to stdout (use journalctl -u vault to see it).
# see https://www.vaultproject.io/docs/commands/audit/enable.html
# see https://www.vaultproject.io/docs/audit/file.html log_raw=true
vault audit enable file file_path=/tmp/vault_audit.log 
vault audit list

# enable the approle authentication method.
# NB this is needed by goldfish and our examples.
#vault auth enable approle

# enable the userpass authentication method.
# NB this is needed by our examples.
vault auth enable userpass

# list enabled authentication methods.
vault auth list

echo "[Setup-Vault] - Configuring the ssh secrets engine"
vault secrets enable -path=ssh ssh
vault write ssh/config/ca generate_signing_key=true
echo '
{
   "allow_user_certificates": true,
   "allowed_users": "*",
   "default_extensions": [{
      "permit-pty": ""
   }],
   "key_type": "ca",
   "key_id_format": "vault-{{role_name}}-{{token_display_name}}-{{public_key_hash}}",
   "default_user": "root",
   "ttl": "30m0s"
}' > ansiblerole.json
vault write ssh/roles/ansible @ansiblerole.json

# Policy
echo "[Setup-Vault] - Writing an ansible-ssh policy"
echo '
path "ssh/sign/ansible" {
capabilities = ["create", "update"]
}
path "kv/*" {
capabilities = ["read"]
}
' | vault policy write ansible-ssh -

# KV Secrets Engine
echo "[Setup-Vault] - Configuring the kv secrets engine"
vault secrets enable -path=kv -version=2 kv
ssh-keygen -t rsa -b 4096 -f ansible-key -q -N ""
vault kv put kv/ansible ssh-private-key=@ansible-key ssh-username=root

# AppRole Auth method
echo "[Setup-Vault] - Configuring the AppRole Auth method"
vault auth enable approle
vault write auth/approle/role/ansible \
  secret_id_ttl=24h \
  secret_id_num_uses=100 \
  token_num_uses=100 \
  token_ttl=24h \
  token_max_ttl=48h \
  policies="ansible-ssh"
#vault read -format=json auth/approle/role/ansible/role-id > role.json
#vault write -format=json -f auth/approle/role/ansible/secret-id > secretid.json

tee ansible-secret-read.json <<EOF
{"policy":"path \"secret/ansible-secret\" {capabilities = [\"read\", \"list\"]}"}
EOF

tee ansible-roleid-read.json <<EOF
{"policy":"path \"auth/approle/role//ansible-secret\" {capabilities = [\"read\", \"list\"]}"}
EOF

# Policy
echo "[Setup-Vault] - Writing an Terraform create token policy"
echo '
path "auth/token/create" {
capabilities = [ "update" ]
}
' | vault policy write terraform-token-create -

vault token create -format=json \
  -policy="ansible-ssh" \
  -policy="terraform-token-create" \
  -metadata="user"="terraform-user" > roleid-token.json

# enable the PostgreSQL database secrets engine.
# NB this is needed by our examples.
#vault secrets enable database
#
## configure the greetings PostgreSQL database.
## see https://learn.hashicorp.com/vault/secrets-management/sm-dynamic-secrets#postgresql
## see https://learn.hashicorp.com/vault/secrets-management/db-root-rotation
## see https://www.postgresql.org/docs/10/static/libpq-connect.html#LIBPQ-CONNSTRING
## see https://www.postgresql.org/docs/10/static/sql-createrole.html
## see https://www.postgresql.org/docs/10/static/sql-grant.html
## see https://www.vaultproject.io/docs/secrets/databases/postgresql.html
## see https://www.vaultproject.io/api/secret/databases/postgresql.html
#vault write database/config/greetings \
#    plugin_name=postgresql-database-plugin \
#    allowed_roles=greetings-admin,greetings-reader \
#    connection_url='postgresql://{{username}}:{{password}}@postgresql.example.com:5432/greetings?sslmode=verify-full' \
#    username=vault \
#    password=abracadabra
##vault write -force database/rotate-root/greetings # immediatly rotate the root password (in this case, the vault username password).
#vault read -format=json database/config/greetings | jq .data
## NB db_name must match the database/config/:db_name
#vault write database/roles/greetings-admin \
#    db_name=greetings \
#    creation_statements="
#create role \"{{name}}\" with login password '{{password}}' valid until '{{expiration}}';
#grant all privileges on all tables in schema public to \"{{name}}\";
#" \
#    default_ttl=1h \
#    max_ttl=24h
#vault read -format=json database/roles/greetings-admin | jq .data
## NB db_name must match the database/config/:db_name
#vault write database/roles/greetings-reader \
#    db_name=greetings \
#    creation_statements="
#create role \"{{name}}\" with login password '{{password}}' valid until '{{expiration}}';
#grant select on all tables in schema public to \"{{name}}\";
#" \
#    default_ttl=1h \
#    max_ttl=24h
#vault read -format=json database/roles/greetings-reader | jq .data
#echo 'You can create a user to administer the greetings database with: vault read database/creds/greetings-admin'
#echo 'You can create a user to access the greetings database with: vault read database/creds/greetings-reader'
#
## create the policy for our use-postgresql example.
#vault policy write use-postgresql - <<EOF
#path "database/creds/greetings-admin" {
#    capabilities = ["read"]
#}
#path "database/creds/greetings-reader" {
#    capabilities = ["read"]
#}
#EOF
#
## create the user for our use-postgresql example.
#vault write auth/userpass/users/use-postgresql \
#    password=abracadabra \
#    policies=use-postgresql
#
## list database connections/names.
#vault list -format=json database/config
#
## list the active secret backends.
#vault secrets list
#
## show the default policy.
## see https://www.vaultproject.io/docs/concepts/policies.html
#vault read sys/policy/default
#
## list the active authentication backends.
## see https://www.vaultproject.io/intro/getting-started/authentication.html
## see https://github.com/hashicorp/vault/issues/3456
#vault path-help sys/auth
#http $VAULT_ADDR/v1/sys/auth "X-Vault-Token: $(cat ~/.vault-token)" \
#    | jq -r 'keys[] | select(endswith("/"))'
#
## write an example secret, read it back and delete it.
## see https://www.vaultproject.io/docs/commands/read-write.html
#echo -n abracadabra | vault write secret/example password=- other_key=value
#vault read -format=json secret/example      # read all the fields as json.
#vault read secret/example                   # read all the fields.
#vault read -field=password secret/example   # read just the password field.
#vault delete secret/example
#vault read secret/example || true
#
# install command line autocomplete.
vault -autocomplete-install

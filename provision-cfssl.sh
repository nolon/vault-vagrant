groupadd --system pki
adduser \
    --system \
    --disabled-login \
    --ingroup pki \
    --home /opt/pki \
    pki
install -d -o pki -g pki -m 755 /opt/pki

for bin in cfssl cfssl-certinfo cfssljson
 do
   echo "Installing $bin..."
 curl -sSL https://github.com/cloudflare/cfssl/releases/download/v1.4.1/${bin}_1.4.1_linux_amd64 > /tmp/${bin}
 sudo install /tmp/${bin} /usr/local/bin/${bin}
done
mkdir -p /opt/pki/ca/config
cat >/opt/pki/ca/config/ca-config.json <<EOF
  {
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "default": {
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
EOF
cat >/opt/pki/ca/config/ca-csr.json <<EOF
{
    "CN": "example.com",
    "hosts": [
        "example.com",
        "www.example.com"
    ],
    "key": {
        "algo": "ecdsa",
        "size": 256
    },
    "names": [
        {
            "C": "CH",
            "ST": "ZH",
            "L": "Zurich"
        }
    ]
}
EOF
cat >/opt/pki/ca/config/vault-csr.json <<EOF
{
  "CN": "vault.example.com",
  "hosts": [
    "vault",
    "127.0.0.1",
    "vault.example.com"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CH",
      "ST": "ZH",
      "L": "Zurich",
      "O": "Kubernetes",
      "OU": "Vault"
    }
  ]
}
EOF

cd /opt/pki/ca/
cfssl genkey -initca config/ca-csr.json | cfssljson -bare ca
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config/ca-config.json -profile=default config/vault-csr.json | cfssljson -bare vault

if [ ! -f /usr/local/share/ca-certificates/ca.pem ]; then
    cp ca.pem /etc/ssl/certs/ca.pem
    cp ca.pem /etc/pki/ca-trust/source/anchors/ca.pem
    update-ca-trust
fi

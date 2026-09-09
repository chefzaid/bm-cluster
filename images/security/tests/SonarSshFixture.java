import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Security;
import java.time.Duration;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import org.apache.sshd.client.SshClient;
import org.apache.sshd.common.config.keys.PublicKeyEntry;
import org.apache.sshd.common.keyprovider.KeyPairProvider;
import org.apache.sshd.common.signature.Signature;
import org.apache.sshd.common.util.security.SecurityUtils;
import org.apache.sshd.server.SshServer;
import org.apache.sshd.server.shell.ProcessShellCommandFactory;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.tmatesoft.svn.core.SVNErrorCode;
import org.tmatesoft.svn.core.SVNErrorMessage;
import org.tmatesoft.svn.core.SVNException;
import org.tmatesoft.svn.core.internal.io.svn.ssh.apache.SshHost;

public class SonarSshFixture {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    private static boolean verifies(KeyPair keys, byte[] message, byte[] bytes) throws Exception {
        Signature signature = SecurityUtils.getEDDSASigner();
        signature.initVerifier(null, keys.getPublic());
        signature.update(null, message);
        return signature.verify(null, bytes);
    }
    public static void main(String[] args) throws Exception {
        Security.addProvider(new BouncyCastleProvider());
        check(SecurityUtils.isEDDSACurveSupported(), "Ed25519 must remain supported");
        check(SecurityUtils.isBouncyCastleRegistered(), "Bouncy Castle must be registered");
        check(!SecurityUtils.isNetI2pCryptoEdDSARegistered(), "The retired provider must be absent");
        KeyPairGenerator generator = KeyPairGenerator.getInstance("Ed25519", "BC");
        KeyPair userKey = generator.generateKeyPair();
        KeyPair hostKey = generator.generateKeyPair();
        byte[] message = "security fixture".getBytes(StandardCharsets.UTF_8);
        Signature signer = SecurityUtils.getEDDSASigner();
        signer.initSigner(null, userKey.getPrivate());
        signer.update(null, message);
        byte[] valid = signer.sign(null);
        check(valid.length == 64 && verifies(userKey, message, valid), "Valid signature must verify");
        byte[] malleable = valid.clone();
        byte[] order = HexFormat.of().parseHex("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010");
        int carry = 0;
        for (int i = 0; i < 32; i++) {
            int sum = (malleable[32 + i] & 255) + (order[i] & 255) + carry;
            malleable[32 + i] = (byte)sum;
            carry = sum >>> 8;
        }
        check(!verifies(userKey, message, malleable), "CVE-2020-36843: non-canonical scalar must be rejected");
        System.out.println("Ed25519 valid signature accepted; non-canonical scalar rejected");
        try (SshServer server = SshServer.setUpDefaultServer(); SshClient client = SshClient.setUpDefaultClient()) {
            server.setHost("127.0.0.1");
            server.setPort(0);
            server.setKeyPairProvider(KeyPairProvider.wrap(hostKey));
            server.setPublickeyAuthenticator((user, key, session) -> user.equals("fixture") && PublicKeyEntry.toString(key).equals(PublicKeyEntry.toString(userKey.getPublic())));
            server.setCommandFactory(ProcessShellCommandFactory.INSTANCE);
            server.start();
            client.setServerKeyVerifier((session, address, key) -> PublicKeyEntry.toString(key).equals(PublicKeyEntry.toString(hostKey.getPublic())));
            client.start();
            try (var session = client.connect("fixture", "127.0.0.1", server.getPort()).verify(Duration.ofSeconds(5)).getSession()) {
                session.addPublicKeyIdentity(userKey);
                session.auth().verify(Duration.ofSeconds(5));
                check(session.isAuthenticated(), "SSH Ed25519 authentication must succeed");
            }
            System.out.println("Apache SSHD authenticates Ed25519 client and host keys");
            String kind = "PRIVATE KEY";
            String encoded = "-----BEGIN " + kind + "-----\n" + Base64.getMimeEncoder(64, new byte[]{10}).encodeToString(userKey.getPrivate().getEncoded()) + "\n-----END " + kind + "-----\n";
            SshHost svn = new SshHost("127.0.0.1", server.getPort());
            svn.setConnectionTimeout(5000);
            svn.setReadTimeout(5000);
            svn.setCredentials("fixture", encoded.toCharArray(), null, null);
            byte[] expectedHost = hostKey.getPublic().getEncoded();
            svn.setHostVerifier((host, port, algorithm, key) -> {
                if (!algorithm.equals(hostKey.getPublic().getAlgorithm()) || !Arrays.equals(key, expectedHost))
                    throw new SVNException(SVNErrorMessage.create(SVNErrorCode.RA_NOT_AUTHORIZED, "Fixture host key mismatch"));
            });
            var session = svn.openSession();
            try {
                session.execCommand("printf fixture-ok");
                String response = new String(session.getOut().readAllBytes(), StandardCharsets.UTF_8);
                check(response.equals("fixture-ok"), "SVNKit SSH command round trip must succeed");
            } finally { session.close(); svn.setDisposed(true); svn.purge(); }
            System.out.println("The scanner's unchanged SVNKit client authenticates and completes an SSH command");
        }
    }
}

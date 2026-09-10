# Platform themes

SonarQube and Vault default to dark mode. Their bottom-right **Dark / Light**
buttons save the choice in the current browser. Odoo's **Dark Mode** user-menu
switch saves an account preference; bootstrap enables it once for the managed
administrator. These preferences survive application restarts.

## SonarQube and Vault

Both themes use vendored Dark Reader assets with their license and provenance
in the source manifests. Their local adaptation runs the style proxy from an
external script, preserving the application's Content Security Policy. Theme
requests stay on the current origin.

- [SonarQube](../k8s/platform/sonarqube.yaml) uses an init container to add
  same-origin theme files to a copy of its HTML entry point. The server mounts
  these files read-only; its application bundles and scanner APIs are unchanged.
- [Vault](../k8s/platform/vault-ui-theme.yaml) uses a separate NGINX helper for
  `/ui` only. The original Ingress routes API requests directly to Vault. The
  helper permits UI GET/HEAD requests, strips forwarded request credentials,
  has no Vault token, and is restricted by network policy. It does not cache
  responses or write access logs.

Keep asset versions and integrity annotations in those manifests. After updating
assets, bump the pod revision and HTML asset query versions. After a theme or
application upgrade, check authenticated navigation, browser console/CSP errors,
both toggle states and reload persistence. For Vault, also check that API health
matches the direct service and the helper rejects API paths.

To restore Sonar's original interface, remove its theme ConfigMap, init
container, volumes and mounts together. Removing the Vault theme Ingress restores
the original `/ui` route; retire the remaining helper resources in the same
change. Neither removal requires changing authentication or application data.

## Odoo

[The Odoo manifest](../k8s/corp/odoo.yaml) vendors OCA's `web_dark_mode` module,
including its source, translations, tests and AGPL license. Bootstrap and the
application mount it read-only under `/mnt/extra-addons`; no startup download is
needed. Other users choose dark mode or the device preference themselves.

When updating the module, check Odoo compatibility, update its provenance and
Deployment revision, then validate the repository and test an authenticated
`/odoo` page. Confirm that the dark CSS loads and the switch works both ways.
Use the switch to disable the theme for an account. Uninstall the module from
Odoo before removing its files.

/**
 * Anonymous Apex — verify the Dropbox Named Credentials (KAN-45 / KAN-56).
 *
 * Prerequisites:
 *   - External Credential  : Dropbox_OAuth   (OAuth 2.0, Browser Flow, Named Principal authenticated)
 *   - Named Credential     : Dropbox_API     -> https://api.dropboxapi.com
 *   - Named Credential     : Dropbox_Content -> https://content.dropboxapi.com
 *   - Both with "Generate Authorization Header" = ON
 *   - The RUNNING USER must have a permission set granting access to the
 *     External Credential Principal, or every call returns 401.
 *
 * Run in Developer Console -> Debug -> Open Execute Anonymous Window,
 * tick "Open Log", and read the USER_DEBUG lines.
 */

// ============================================================
// TEST 1 — Connectivity only. Run this first.
// ============================================================
// Dropbox's /2/check/user exists purely to validate a token and echo a string
// back. HTTP 200 with your query returned means: the Named Credential resolved,
// the token was injected, and the token is valid. Nothing else is proven yet.

String echoValue = 'named-credential-test';

HttpRequest checkReq = new HttpRequest();
checkReq.setEndpoint('callout:Dropbox_API/2/check/user');
checkReq.setMethod('POST');
checkReq.setHeader('Content-Type', 'application/json');
checkReq.setBody(JSON.serialize(new Map<String, Object>{ 'query' => echoValue }));
checkReq.setTimeout(30000);

HttpResponse checkRes = new Http().send(checkReq);

System.debug('=== TEST 1: /2/check/user ===');
System.debug('Status : ' + checkRes.getStatusCode() + ' ' + checkRes.getStatus());
System.debug('Body   : ' + checkRes.getBody());
System.debug(checkRes.getStatusCode() == 200 && checkRes.getBody().contains(echoValue)
    ? 'PASS — Dropbox_API is wired up and the access token is valid.'
    : 'FAIL — see the error table in the comments at the bottom.');


// ============================================================
// TEST 2 — Full round trip: upload, share, temp link, delete.
// ============================================================
// Exercises BOTH Named Credentials. Uploads a tiny throwaway file, creates a
// shared link, requests a short-lived temporary link, then deletes the file so
// the App folder is left clean.

Http http = new Http();
String testPath = '/named-credential-test-' + Datetime.now().getTime() + '.txt';
Boolean allPassed = true;

// --- 2a. UPLOAD (content host) ------------------------------------------
// The body is RAW BYTES, not JSON. Parameters travel in the Dropbox-API-Arg
// header. Content-Type MUST be application/octet-stream.
//
// Dropbox-API-Arg must be ASCII-only — see asciiEscape() at the bottom of this
// file. Not an edge case for this project: applicant names and document titles
// routinely contain non-Latin characters.

Map<String, Object> uploadArgs = new Map<String, Object>{
    'path'       => testPath,
    'mode'       => 'add',
    'autorename' => true,
    'mute'       => true
};

HttpRequest upReq = new HttpRequest();
upReq.setEndpoint('callout:Dropbox_Content/2/files/upload');
upReq.setMethod('POST');
upReq.setHeader('Dropbox-API-Arg', JSON.serialize(uploadArgs)); // ASCII-safe here: path is ASCII
upReq.setHeader('Content-Type', 'application/octet-stream');
upReq.setBodyAsBlob(Blob.valueOf('Named Credential smoke test. Safe to delete.'));
upReq.setTimeout(60000);

HttpResponse upRes = http.send(upReq);
System.debug('=== TEST 2a: /2/files/upload (Dropbox_Content) ===');
System.debug('Status : ' + upRes.getStatusCode());
System.debug('Body   : ' + upRes.getBody());
allPassed = allPassed && upRes.getStatusCode() == 200;

String uploadedPath;
if (upRes.getStatusCode() == 200) {
    Map<String, Object> meta = (Map<String, Object>) JSON.deserializeUntyped(upRes.getBody());
    uploadedPath = (String) meta.get('path_lower');
    System.debug('Uploaded to: ' + uploadedPath + ' (' + meta.get('size') + ' bytes)');
}

// --- 2b. CREATE SHARED LINK (api host) ----------------------------------
if (uploadedPath != null) {
    HttpRequest linkReq = new HttpRequest();
    linkReq.setEndpoint('callout:Dropbox_API/2/sharing/create_shared_link_with_settings');
    linkReq.setMethod('POST');
    linkReq.setHeader('Content-Type', 'application/json');
    linkReq.setBody(JSON.serialize(new Map<String, Object>{ 'path' => uploadedPath }));
    linkReq.setTimeout(30000);

    HttpResponse linkRes = http.send(linkReq);
    System.debug('=== TEST 2b: create_shared_link_with_settings (Dropbox_API) ===');
    System.debug('Status : ' + linkRes.getStatusCode());
    System.debug('Body   : ' + linkRes.getBody());
    allPassed = allPassed && linkRes.getStatusCode() == 200;
    // NOTE: a shared link is a BEARER URL — anyone holding it can read the file.
    // Production should prefer get_temporary_link (below). See design doc §10.1.
}

// --- 2c. TEMPORARY LINK (api host) --------------------------------------
// 4-hour expiry. This is what a real deployment should hand to the portal,
// rather than a persistent shared link.
if (uploadedPath != null) {
    HttpRequest tmpReq = new HttpRequest();
    tmpReq.setEndpoint('callout:Dropbox_API/2/files/get_temporary_link');
    tmpReq.setMethod('POST');
    tmpReq.setHeader('Content-Type', 'application/json');
    tmpReq.setBody(JSON.serialize(new Map<String, Object>{ 'path' => uploadedPath }));
    tmpReq.setTimeout(30000);

    HttpResponse tmpRes = http.send(tmpReq);
    System.debug('=== TEST 2c: get_temporary_link (Dropbox_API) ===');
    System.debug('Status : ' + tmpRes.getStatusCode());
    System.debug('Body   : ' + tmpRes.getBody());
    allPassed = allPassed && tmpRes.getStatusCode() == 200;
}

// --- 2d. CLEAN UP (api host) --------------------------------------------
if (uploadedPath != null) {
    HttpRequest delReq = new HttpRequest();
    delReq.setEndpoint('callout:Dropbox_API/2/files/delete_v2');
    delReq.setMethod('POST');
    delReq.setHeader('Content-Type', 'application/json');
    delReq.setBody(JSON.serialize(new Map<String, Object>{ 'path' => uploadedPath }));
    delReq.setTimeout(30000);

    HttpResponse delRes = http.send(delReq);
    System.debug('=== TEST 2d: delete_v2 (cleanup) ===');
    System.debug('Status : ' + delRes.getStatusCode());
    allPassed = allPassed && delRes.getStatusCode() == 200;
}

System.debug(allPassed
    ? 'ALL PASSED — both Named Credentials work, upload/share/link/delete round trip is clean.'
    : 'SOMETHING FAILED — check the status codes above against the error table.');


/* =========================================================================
 * ASCII escaping helper — copy into DropboxStorageProvider.
 * Dropbox rejects a Dropbox-API-Arg header containing non-ASCII bytes.
 * =========================================================================
 *
 *   public static String asciiEscape(String input) {
 *       String out = '';
 *       for (Integer i = 0; i < input.length(); i++) {
 *           String ch = input.substring(i, i + 1);
 *           Integer code = ch.getChars()[0];
 *           out += (code > 127)
 *               ? '\\u' + ('0000' + Integer.toHexString(code)).right(4)
 *               : ch;
 *       }
 *       return out;
 *   }
 *
 * Use as: upReq.setHeader('Dropbox-API-Arg', asciiEscape(JSON.serialize(args)));
 * Add a test case with an Arabic or Chinese filename.
 *
 * =========================================================================
 * ERROR TABLE — what each failure actually means
 * =========================================================================
 *
 * System.CalloutException: "Unauthorized endpoint"
 *     The Named Credential name is misspelled, so Apex treated 'callout:X' as a
 *     literal URL and looked for a Remote Site Setting. Check the spelling and
 *     that you used the DEVELOPER NAME, not the label.
 *
 * 401 + {"error_summary":"invalid_access_token/..."}
 *     Either the External Credential Principal was never authenticated (go to
 *     the External Credential, Principals, Actions -> Authenticate), or the
 *     running user has no permission set granting access to that Principal.
 *     This is the single most common failure.
 *
 * 401 + {"error_summary":"expired_access_token/..."}
 *     Refresh is not happening. token_access_type=offline was almost certainly
 *     missing from the Auth. Provider's Authorize Endpoint URL, so no refresh
 *     token was ever issued. Fix the Auth. Provider and RE-AUTHENTICATE.
 *
 * 401 + {"error_summary":"missing_scope/..."}
 *     The scope is not on the token. Adding a scope in the Dropbox App Console
 *     does NOT apply retroactively — scopes are baked in at authorization time.
 *     You must re-authenticate the principal after changing scopes.
 *
 * 400 "Error in call to API function ... request body: expected null"
 *     You sent a Content-Type or body to an endpoint that takes neither.
 *
 * 400 on upload, "Bad HTTP request"
 *     Usually Content-Type is not application/octet-stream, or the parameters
 *     were put in the body instead of the Dropbox-API-Arg header.
 *
 * 409 + path/conflict
 *     File already exists. 'mode':'add' with 'autorename':true avoids this.
 *
 * 429
 *     Rate limited. Honour the Retry-After header — worth a test case
 *     (see KAN-216).
 */
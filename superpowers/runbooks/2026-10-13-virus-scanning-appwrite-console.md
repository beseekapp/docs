# Virus Scanning: Appwrite Console steps (test server)

Epic V · ADR-0064 · Card V1 (#78). Appwrite **1.8.1** on `3.90.155.157`.

These steps replace the `provision database` run, which fails because the shared API key cannot manage tables or columns. Do them in order. When you're finished, send back the **quarantine bucket ID** from step 3.

| Thing | Value |
|---|---|
| Project ID | `6a6e258f003e5b63d852` |
| Database ID | `6a7038dd00376679c8dc` |
| Main files bucket ID | `6a7038f000116c80cdc1` |
| Upload limit (`_APP_STORAGE_LIMIT`) | 30 MB |

> Appwrite 1.8 renamed things in the Console: **collections are "Tables"**, **attributes are "Columns"**, **documents are "Rows"**. Older menus or docs may still use the old names.

---

## 1. Open the Console

1. Start the tunnel from your machine:
   ```bash
   p40tunnel -d          # forwards Appwrite to localhost:9080
   ```
2. Open **http://localhost:9080** and sign in with the console admin account.
3. Open the project whose ID is `6a6e258f003e5b63d852`. The ID is shown on the project card and in the URL.

## 2. Add the `scan_status` column to `file_metadata`

1. In the left sidebar, open **Databases** and click the database `6a7038dd00376679c8dc`.
2. Open the table **`file_metadata`** (named *File Metadata*).
3. Go to the **Columns** tab and click **Create column**, then choose **String** (shown as *Text / String* in some builds).
4. Fill in:

   | Field | Value |
   |---|---|
   | Key | `scan_status` |
   | Size | `20` |
   | Required | **off** |
   | Default | *(leave empty)* |
   | Array | **off** |
   | Encrypt | **off** |

5. Click **Create**. Wait until the column's status changes from *processing* to **available**. Refresh after a few seconds.

**Check:** `scan_status` is listed as `string(20)`, not required, status *available*. Existing rows show it as empty (`null`). That's expected and means "predates scanning".

> Don't make it an enum, and don't set a default. Transformer writes `pending`, `clean`, `infected` or `unscannable`, and an empty value must stay empty.

## 3. Create the `quarantine` bucket

1. In the left sidebar, open **Storage** and click **Create bucket**.
2. Name: `quarantine`. Bucket ID: leave **auto-generated** (or type `quarantine`). Click **Create**.
3. Open the new bucket and go to **Settings**:

   | Setting | Value |
   |---|---|
   | Permissions | **remove everything**. No roles at all: no `any`, no `users`, no teams. Only server API keys may access it. |
   | File security | **off** |
   | Enabled | **on** |
   | Maximum file size | `30` MB (match `_APP_STORAGE_LIMIT`) |
   | Allowed file extensions | *(empty: allow all)* |
   | Compression | **none** (keep the original bytes intact for evidence and restore) |
   | Encryption | **on** |
   | Antivirus | **off** (Appwrite's own scanner is not used; transformer does the scanning) |

4. Click **Update** on each section you changed.
5. **Copy the bucket ID** from the bucket's header or URL.

**Check:**
- The bucket's Permissions tab is empty.
- Files in this bucket can't be opened from the webapp, because no user role has access.

## 4. Confirm the shared API key can use the bucket

Transformer uses the shared server key (the same one in its `.env`). It has to be able to write to and delete from both buckets, and update rows.

1. In the left sidebar, open **Overview**, then **Integrations** and **API keys** (in some builds: **Settings → API keys**).
2. Open the key used by the services. If there's more than one, it's the one whose secret matches `APPWRITE_API_KEY` in `platform40/microservices/transformer/.env`; the name usually gives it away.
3. Under **Scopes**, make sure these are ticked:

   | Scope | Why |
   |---|---|
   | `files.read`, `files.write` | download from the main bucket, copy into quarantine, delete the original |
   | `rows.read`, `rows.write` *(older name: `documents.*`)* | set `scan_status` |

   Bucket-level scopes such as `buckets.*` are **not** needed.
4. Save if you changed anything.

> Optional, separate from this rollout: to let `provision database` work again, create a **separate** key named e.g. `provisioning` with `databases.*`, `tables.*`/`collections.*`, `columns.*`/`attributes.*` and `indexes.*`, and put it **only** in `platform40/appwrite/provisioning/.env`. Don't add these scopes to the shared service key.

## 5. Send back

- [ ] Step 2 done: `scan_status` is *available*
- [ ] Step 3 done: **quarantine bucket ID = `__________`**
- [ ] Step 4 done: the scopes are confirmed

With those, the rollout continues without further Console work:

1. Write the server transformer `.env`: `CLAMAV_HOST=clamav`, `CLAMAV_PORT=3310`, `SCAN_ENABLED=false`, `QUARANTINE_BUCKET_ID=<id>`. That file has Windows (CRLF) line endings, so the new lines are written to match.
2. Deploy V2 transformer (scanning off), then deploy V3 webapp (`deploy-to-remote.sh --ref …`).
3. Set `SCAN_ENABLED=true`, then test with an EICAR file and a clean PDF.

## Rollback

- **Column:** leave it. Empty values are harmless and webapp treats them as clean. If you do remove it, first set `SCAN_ENABLED=false` on transformer, or every scan will fail to write its status.
- **Bucket:** it can be deleted once `SCAN_ENABLED=false` and it has been emptied (or after restoring any files you need).

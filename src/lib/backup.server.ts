/**
 * Backup engine: builds a cumulative JSON snapshot of the whole company
 * archive and uploads it to the `20s` folder in the connected Google Drive.
 * Read-only against business data — it never mutates existing records.
 */

const GATEWAY = "https://connector-gateway.lovable.dev/google_drive";
const FOLDER_NAME = "20s";
const FOLDER_MIME = "application/vnd.google-apps.folder";

export type BackupResult = {
  status: "success" | "failed";
  file_name: string;
  file_size_bytes: number;
  drive_file_id: string | null;
  drive_link: string | null;
  drive_folder_id: string | null;
  uploaded: boolean;
  note: string | null;
  error_message: string | null;
};

/** `<prefix>_YYYY-MM-DD_HHmmss.json` in local (UTC) time. */
function snapshotFileName(prefix = "20s_backup", date = new Date()) {
  const iso = date.toISOString();
  const day = iso.slice(0, 10);
  const time = iso.slice(11, 19).replace(/:/g, "");
  return `${prefix}_${day}_${time}.json`;
}

function gatewayHeaders() {
  const lovableKey = process.env["LOVABLE_API_KEY"];
  const connectionKey = process.env["GOOGLE_DRIVE_API_KEY"];
  if (!lovableKey || !connectionKey) return null;
  return {
    Authorization: `Bearer ${lovableKey}`,
    "X-Connection-Api-Key": connectionKey,
  };
}

async function readOrThrow(response: Response, label: string) {
  const text = await response.text();
  if (!response.ok) throw new Error(`${label} failed [${response.status}]: ${text}`);
  return text ? (JSON.parse(text) as Record<string, unknown>) : {};
}

/** Finds the `20s` root folder, creating it on first run. */
async function resolveFolderId(headers: Record<string, string>) {
  const query = encodeURIComponent(
    `name = '${FOLDER_NAME}' and mimeType = '${FOLDER_MIME}' and trashed = false`,
  );
  const search = await fetch(
    `${GATEWAY}/drive/v3/files?q=${query}&fields=files(id,name)&pageSize=10`,
    { headers },
  );
  const found = (await readOrThrow(search, "Drive folder lookup")) as {
    files?: { id: string }[];
  };
  const existing = found.files?.[0]?.id;
  if (existing) return existing;

  const created = await fetch(`${GATEWAY}/drive/v3/files?fields=id`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ name: FOLDER_NAME, mimeType: FOLDER_MIME }),
  });
  const folder = (await readOrThrow(created, "Drive folder create")) as { id?: string };
  if (!folder.id) throw new Error("Drive folder create returned no id");
  return folder.id;
}

async function uploadToDrive(fileName: string, payload: string) {
  const headers = gatewayHeaders();
  if (!headers) {
    return {
      driveFileId: null,
      driveLink: null,
      folderId: null,
      note: "Google Drive is not connected — snapshot generated but not uploaded.",
    };
  }

  const folderId = await resolveFolderId(headers);

  const form = new FormData();
  form.append(
    "metadata",
    new Blob([JSON.stringify({ name: fileName, parents: [folderId] })], {
      type: "application/json",
    }),
  );
  form.append("file", new Blob([payload], { type: "application/json" }), fileName);

  const response = await fetch(
    `${GATEWAY}/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink`,
    { method: "POST", headers, body: form },
  );
  const file = (await readOrThrow(response, "Drive upload")) as {
    id?: string;
    webViewLink?: string;
  };
  if (!file.id) throw new Error("Drive upload returned no file id");
  return {
    driveFileId: file.id,
    driveLink: file.webViewLink ?? `https://drive.google.com/file/d/${file.id}/view`,
    folderId,
    note: null,
  };
}

/**
 * Runs a full cumulative backup for one company and records the outcome in
 * backup_history. Never throws: failures are logged so the caller can report them.
 */
export async function runBackupForCompany(
  companyId: string,
  filePrefix = "20s_backup",
): Promise<BackupResult> {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const fileName = snapshotFileName(filePrefix);

  try {
    const { data, error } = await supabaseAdmin.rpc("company_financial_snapshot", {
      _company_id: companyId,
    });
    if (error) throw new Error(error.message);

    const payload = JSON.stringify(data);
    const sizeBytes = new TextEncoder().encode(payload).byteLength;
    const { driveFileId, driveLink, folderId, note } = await uploadToDrive(fileName, payload);

    await supabaseAdmin.from("backup_history").insert({
      company_id: companyId,
      status: "success",
      file_name: fileName,
      file_size_bytes: sizeBytes,
      drive_file_id: driveFileId,
      drive_link: driveLink,
      drive_folder_id: folderId,
      error_message: note,
    });

    return {
      status: "success",
      file_name: fileName,
      file_size_bytes: sizeBytes,
      drive_file_id: driveFileId,
      drive_link: driveLink,
      drive_folder_id: folderId,
      uploaded: Boolean(driveFileId),
      note,
      error_message: null,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Backup failed:", message);
    await supabaseAdmin.from("backup_history").insert({
      company_id: companyId,
      status: "failed",
      file_name: fileName,
      error_message: message.slice(0, 500),
    });
    return {
      status: "failed",
      file_name: fileName,
      file_size_bytes: 0,
      drive_file_id: null,
      drive_link: null,
      drive_folder_id: null,
      uploaded: false,
      note: null,
      error_message: message.slice(0, 500),
    };
  }
}

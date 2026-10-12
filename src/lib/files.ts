/** Reads a browser File into a base64 payload for server-function uploads. */
export async function fileToPayload(file: File) {
  const buffer = await file.arrayBuffer();
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return {
    name: file.name,
    mime: file.type || "application/octet-stream",
    data: btoa(binary),
  };
}

export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;

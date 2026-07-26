type MirrorRow = Record<string, unknown>

function stableJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`
  }
  if (value && typeof value === "object") {
    const record = value as MirrorRow
    return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${stableJson(record[key])}`).join(",")}}`
  }
  return JSON.stringify(value)
}

async function sha256Hex(input: string): Promise<string> {
  const encoded = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", encoded)
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

async function diff(leftPath: string, rightPath: string): Promise<void> {
  const left = JSON.parse(await Deno.readTextFile(leftPath)) as MirrorRow[]
  const right = JSON.parse(await Deno.readTextFile(rightPath)) as MirrorRow[]
  const leftHash = await sha256Hex(stableJson(left))
  const rightHash = await sha256Hex(stableJson(right))
  if (leftHash !== rightHash) {
    console.error(`mirror diff: ${leftHash} != ${rightHash}`)
    Deno.exit(1)
  }
  console.log(`mirror clean: ${leftHash}`)
}

if (import.meta.main) {
  const [command, leftPath, rightPath] = Deno.args
  if (command !== "diff" || !leftPath || !rightPath) {
    console.error("usage: deno run --allow-read Tools/ecosystem-mirror.ts diff standalone.json unified.json")
    Deno.exit(64)
  }
  await diff(leftPath, rightPath)
}

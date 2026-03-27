import { S3Client, ListObjectsV2Command, GetObjectCommand } from "@aws-sdk/client-s3"

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL

if (!supabaseUrl) {
  throw new Error("NEXT_PUBLIC_SUPABASE_URL is required in the environment (expected format: https://{ref}.supabase.co)")
}

const projectRef = supabaseUrl.match(/https:\/\/(.+?)\.supabase/)?.[1]

if (!projectRef) {
  throw new Error(
    `NEXT_PUBLIC_SUPABASE_URL must be in the form "https://{ref}.supabase.co" (received: "${supabaseUrl}")`
  )
}

if (!process.env.S3_ACCESS_KEY_ID || !process.env.S3_SECRET_ACCESS_KEY) {
  throw new Error("S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are required in .env.local")
}

export const s3 = new S3Client({
  region: "us-east-1",
  endpoint: `https://${projectRef}.supabase.co/storage/v1/s3`,
  credentials: {
    accessKeyId: process.env.S3_ACCESS_KEY_ID,
    secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
  },
  forcePathStyle: true,
})

export const BUCKET = "lake"

/**
 * List all objects in the bucket with automatic pagination.
 * @param {string} [prefix] - Optional prefix filter (e.g. "creditsafe/")
 * @returns {Promise<import("@aws-sdk/client-s3")._Object[]>}
 */
export async function listAll(prefix) {
  const files = []
  let token
  do {
    const { Contents, NextContinuationToken } = await s3.send(
      new ListObjectsV2Command({
        Bucket: BUCKET,
        Prefix: prefix,
        MaxKeys: 1000,
        ContinuationToken: token,
      })
    )
    if (Contents) files.push(...Contents)
    token = NextContinuationToken
  } while (token)
  return files
}

/**
 * Download and parse a JSON file from the bucket.
 * @param {string} key - The S3 object key
 * @returns {Promise<any>}
 */
export async function getJson(key) {
  const response = await s3.send(
    new GetObjectCommand({ Bucket: BUCKET, Key: key })
  )
  const body = await response.Body?.transformToString()
  return JSON.parse(body || "{}")
}

export { ListObjectsV2Command, GetObjectCommand }

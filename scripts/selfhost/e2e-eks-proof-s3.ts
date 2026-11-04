// Pod Identity -> S3 round trip through the services image's own Locker
// adapter (src/shared/locker.ts), run in the alleyoop pod by e2e-eks-proof.sh.
// Writes, reads back, lists and deletes one object under e2e-eks-proof/.
const { lockerStore, credentialSource } = await import("/app/src/shared/locker.ts");
const { objectKey, readAll } = await import("/app/src/shared/vendor.ts");
const raw = lockerStore();
const key = `e2e-eks-proof/${Date.now()}.txt`;
const body = new TextEncoder().encode("eks pod identity probe");
const out = (r: string, c: string, d: string) => console.log(`EKS|${r}|${c}|${d}`);
try {
  await raw.store.put(objectKey(key), body, { ifNoneMatch: true, contentType: "text/plain" });
  const head = await raw.store.head(objectKey(key));
  const got = new TextDecoder().decode(await readAll(await raw.store.get(objectKey(key))));
  const listed = await raw.store.list(objectKey("e2e-eks-proof"));
  out(got === "eks pod identity probe" ? "PASS" : "FAIL", "eks.s3_locker_roundtrip",
    `credentials=${credentialSource()} bucket=${process.env.LOCKER_BUCKET} key=${key} head=${head ? "found" : "none"} listed=${listed.items.length} read_back=${got === "eks pod identity probe"}`);
  if (typeof (raw.store as any).delete === "function") { await (raw.store as any).delete(objectKey(key)); out("PASS", "eks.s3_locker_delete", `key=${key}`); }
} catch (e) {
  out("FAIL", "eks.s3_locker_roundtrip", String((e as Error).message).slice(0, 200));
}

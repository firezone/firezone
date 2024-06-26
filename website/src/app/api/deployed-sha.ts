// pages/api/deployed-sha.ts
import { NextApiRequest, NextApiResponse } from "next";

export default function handler(req: NextApiRequest, res: NextApiResponse) {
  const sha = process.env.FIREZONE_DEPLOYED_SHA;
  res.status(200).json({ sha });
}

import * as fs from 'fs'
import { parse } from 'yaml'

export function parseValues(path: string) {
  const file = fs.readFileSync(path, 'utf8')
  return parse(file)
}

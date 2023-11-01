import fs from 'node:fs/promises';
import express from 'express';
import asyncHandler from "express-async-handler";
import { SecretManagerServiceClient } from '@google-cloud/secret-manager';
import { exec } from 'promisify-child-process';
import { file } from 'tmp-promise'

// Names of Google Secret Manager secrets
const PROVIDER_FILE_SECRET_NAME = (() => {
    const envVar = process.env.PROVIDER_FILE_SECRET_NAME;
    if (!envVar) {
        throw new Error("PROVIDER_FILE_SECRET_NAME environment variable is required");
    }
    return envVar;
})()
const BZERO_FILE_SECRET_NAME = (() => {
    const envVar = process.env.BZERO_FILE_SECRET_NAME;
    if (!envVar) {
        throw new Error("BZERO_FILE_SECRET_NAME environment variable is required");
    }
    return envVar;
})()

// Verify the zli executable is available at startup instead of waiting for a
// first request
await fs.access('/usr/bin/zli', fs.constants.X_OK);

// Use secret manager to get credentials required to run `zli service-account
// login`
const secretClient = new SecretManagerServiceClient();

/**
 * Load a secret from the secret manager
 * @param secretName Name of the secret
 * @returns The contents of the secret value
 */
async function loadSecretFromSecretManager(secretName: string) {
    const [accessResponse] = await secretClient.accessSecretVersion({
        name: secretName,
    });
    return accessResponse.payload?.data?.toString();
}

// Fetch the credentials
const providerCredentials = await loadSecretFromSecretManager(PROVIDER_FILE_SECRET_NAME);
const bzeroCredentials = await loadSecretFromSecretManager(BZERO_FILE_SECRET_NAME);

// Fail early if fetched credentials are empty
if (!providerCredentials || !bzeroCredentials) {
    throw new Error("One of the required credential secrets is empty");
}

/**
 * Execute a command, wait for it to complete, and capture stdout and stderr
 * @param cmd The command to execute
 * @returns The captured stdout and stderr outputs
 */
async function execCommand(cmd: string): Promise<string> {
    const { stdout, stderr } = await exec(cmd);
    return [stdout, stderr].join('\n');
}

/**
 * Runs `zli service-account login` using the fetched credentials
 * @returns The stdout and stderr output from the `zli`
 */
async function zliServiceAccountLogin(): Promise<string> {
    // Create temp files (cleaned up after done using them) to store credentials
    // on disk. `zli service-account login` only takes in filepaths right now
    const { path: providerFilePath, cleanup: cleanupProviderFile } = await file();
    const { path: bzeroFilePath, cleanup: cleanupBzeroFile } = await file();
    try {
        await fs.writeFile(providerFilePath, providerCredentials as string);
        await fs.writeFile(bzeroFilePath, bzeroCredentials as string);
        return await execCommand(`zli service-account login --providerCreds ${providerFilePath} --bzeroCreds ${bzeroFilePath}`);
    } finally {
        await cleanupBzeroFile();
        await cleanupProviderFile();
    }
}

// Define route handlers
export const app = express();

// Display zli version
app.get('/', asyncHandler(async (_, res) => {
    res.send(await execCommand('zli --version'))
}));

// Login to BastionZero using SA credentials
app.get('/login', asyncHandler(async (_, res) => {
    const zliLoginOutput = await zliServiceAccountLogin()
    res.send(zliLoginOutput);
}));

// Generate SSH config
app.get('/generate', asyncHandler(async (_, res) => {
    const generateOutput = await execCommand('zli generate sshConfig')
    res.send(generateOutput);
}));

// In-memory constants used to skip some steps in /ssh after first successful
// request for a given CloudRun container. Call `/generate` to force re-generate
// the sshConfig. Call `/login` to force re-login.
let loggedIn: boolean = false;
let generatedSshConfig: boolean = false;

// SSH example
app.get('/ssh', asyncHandler(async (req, res) => {
    if (!loggedIn) {
        // Login to BastionZero using SA credentials
        const zliLoginOutput = await zliServiceAccountLogin();
        console.log(`zli service-account login: ${zliLoginOutput}`);
        loggedIn = true;
    }

    // Build ssh command from query. Set some defaults if query parameters are
    // missing
    let sshUserString: string = "root";
    let sshHostString: string = "";
    let sshCommandString: string = "uname -a";
    if (req.query.user) {
        sshUserString = req.query.user as string;
    }
    if (req.query.host) {
        sshHostString = req.query.host as string;
    } else {
        throw new Error("Please specify a host in the query parameters");
    }
    if (req.query.cmd) {
        sshCommandString = req.query.cmd as string;
    }
    const constructedSshCmd = `ssh -F /home/.ssh/config ${sshUserString}@${sshHostString} ${sshCommandString}`;
    console.log(`SSH command: ${constructedSshCmd}`);

    try {
        if (!generatedSshConfig) {
            // Generate ssh config
            const generateOutput = await execCommand('zli generate sshConfig')
            console.log(`zli generate sshConfig: ${generateOutput}`);
            generatedSshConfig = true;
        }

        // SSH!
        const sshOutput = await execCommand(constructedSshCmd);
        res.send(sshOutput);
    } catch (error) {
        // It could be that re-login fixes the issue
        loggedIn = false;
        throw error;
    }
}));
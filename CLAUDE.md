# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository containing shell configuration files. Currently contains:
- `.bashrc`: Main bash configuration with PATH setup, shell options, Git prompt integration, and various shell customizations

## Important Security Note

**WARNING**: The .bashrc file contains hardcoded AWS credentials (lines 99-100). These credentials should be removed and stored securely using:
- AWS CLI configuration (`aws configure`)
- Environment variables  
- AWS credentials file (~/.aws/credentials)
- IAM roles for EC2 instances

## File Structure

- `.bashrc`: Main bash configuration file with:
  - PATH modifications for local binaries (/home/yom/bin, /home/yom/go/bin, /home/yom/.local/bin)
  - Git prompt status configuration
  - Shell history and completion settings
  - AWS and Go environment variables

## No Build/Test Commands

This repository contains configuration files only - no build, test, or lint commands are applicable.
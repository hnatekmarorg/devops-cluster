package main

import (
	"bytes"
	"embed"
	"fmt"
	"text/template"
)

//go:embed templates/*
var templatesFS embed.FS

type RenderData struct {
	*Config
	StateKey          string
	MultiControlPlane bool
}

func RenderFile(tmplName string, data RenderData) (string, error) {
	content, err := templatesFS.ReadFile("templates/" + tmplName)
	if err != nil {
		return "", err
	}
	tmpl, err := template.New(tmplName).Parse(string(content))
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// RenderAll returns every file PR 2 creates, keyed by repo-relative path.
func RenderAll(cfg *Config) (map[string]string, error) {
	data := RenderData{
		Config:            cfg,
		StateKey:          fmt.Sprintf("cluster-%s/terraform.tfstate", cfg.ClusterName),
		MultiControlPlane: countRole(cfg.Nodes, "controlplane") > 1,
	}

	files := map[string]string{}
	clusterDir := fmt.Sprintf("terraform/clusters/%s", cfg.ClusterName)

	for tmplName, path := range map[string]string{
		"versions.tf":       clusterDir + "/versions.tf",
		"providers.tf":      clusterDir + "/providers.tf",
		"backend.tf":        clusterDir + "/backend.tf",
		"main.tf":           clusterDir + "/main.tf",
		"cluster-base.yaml": fmt.Sprintf("bootstrap/argocd/%s/cluster-base.yaml", cfg.ClusterName),
	} {
		rendered, err := RenderFile(tmplName, data)
		if err != nil {
			return nil, fmt.Errorf("rendering %s: %w", tmplName, err)
		}
		files[path] = rendered
	}
	return files, nil
}
